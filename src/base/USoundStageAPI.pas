{* SoundStage HTTP API for USDX
 *
 * Exposes a small HTTP control surface for the SoundStage karaoke
 * queue system (see ~/Personal/sound-stage). HTTP handler threads
 * enqueue commands onto a thread-safe queue; the USDX main thread
 * drains that queue once per frame and executes against USDX state.
 * Handlers block on a per-command event for the reply.
 *}

unit USoundStageAPI;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  SysUtils,
  SyncObjs,
  Sockets,
  fphttpserver,
  httpdefs;

type
  TSoundStageCmdKind = (cmdNowPlaying, cmdSongs, cmdPause, cmdResume, cmdPlay, cmdDebugState);

  TSoundStageCmd = class
  private
    FRefCount: integer;
  public
    Kind: TSoundStageCmdKind;
    ReplyEvent: TEvent;
    ReplyJSON: string;
    ReplyStatus: integer;
    // cmdPlay payload — parsed from request body on the handler thread,
    // consumed on the main thread by the drain handler.
    PlaySongId: integer;
    PlayRequester: UTF8String;
    PlayPlayers: integer;   // 1 or 2; -1 = omitted (only honored on first /play of session)
    constructor Create(AKind: TSoundStageCmdKind);
    destructor Destroy; override;
    procedure Release;
  end;

  TSoundStageListener = class(TThread)
  private
    FServer: TFPHTTPServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TFPHTTPServer);
  end;

  TSoundStageServer = class
  private
    FServer: TFPHTTPServer;
    FListener: TSoundStageListener;
    FQueue: TThreadList;
    FPort: integer;
    FEnabled: boolean;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    function Enqueue(Kind: TSoundStageCmdKind; TimeoutMs: Cardinal): TSoundStageCmd;
  public
    constructor Create(APort: integer);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure Drain;
    property Enabled: boolean read FEnabled;
  end;

var
  SoundStageServer: TSoundStageServer = nil;

implementation

uses
  fpjson,
  jsonparser,
  UAvatars,
  UCommon,
  UDisplay,
  UGraphic,
  UIni,
  UNote,
  UPath,
  UPathUtils,
  UScreenNextUp,
  UScreenScore,
  UScreenSingController,
  USkins,
  USongs,
  UMusic,
  UTexture,
  UThemes,
  ULog;

// Minimal JSON string escaper. Handles the JSON-required escapes plus
// ASCII control chars; UTF-8 continuation bytes (>= 0x80) pass through
// unchanged, producing valid JSON.
function JsonStr(const S: UTF8String): UTF8String;
var
  I: Integer;
  C: AnsiChar;
begin
  Result := '"';
  for I := 1 to System.Length(S) do
  begin
    C := S[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(C) < $20 then
        Result := Result + Format('\u%.4x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

{ TSoundStageCmd }

constructor TSoundStageCmd.Create(AKind: TSoundStageCmdKind);
begin
  inherited Create;
  FRefCount := 2;
  Kind := AKind;
  ReplyEvent := TEvent.Create(nil, True, False, '');
  ReplyJSON := '';
  ReplyStatus := 500;
  PlaySongId := -1;
  PlayRequester := '';
  PlayPlayers := -1;
end;

destructor TSoundStageCmd.Destroy;
begin
  ReplyEvent.Free;
  inherited;
end;

procedure TSoundStageCmd.Release;
begin
  if InterlockedDecrement(FRefCount) = 0 then
    Self.Free;
end;

{ TSoundStageListener }

constructor TSoundStageListener.Create(AServer: TFPHTTPServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSoundStageListener.Execute;
begin
  try
    FServer.Active := True;
  except
    on E: Exception do
      Log.LogError('SoundStage listener: ' + E.Message, 'SoundStage');
  end;
end;

{ TSoundStageServer }

constructor TSoundStageServer.Create(APort: integer);
begin
  inherited Create;
  FPort := APort;
  FEnabled := False;
  FServer := nil;
  FListener := nil;
  FQueue := TThreadList.Create;
end;

destructor TSoundStageServer.Destroy;
begin
  Stop;
  FQueue.Free;
  inherited;
end;

procedure TSoundStageServer.Start;
begin
  try
    FServer := TFPHTTPServer.Create(nil);
    FServer.Port := FPort;
    FServer.Threaded := True;
    FServer.OnRequest := HandleRequest;
    // FServer.Active := True blocks in the accept loop — run it in a
    // dedicated listener thread so USDX's main thread can enter MainLoop.
    FListener := TSoundStageListener.Create(FServer);
    FEnabled := True;
    Log.LogStatus(Format('SoundStage HTTP API listening on port %d', [FPort]), 'SoundStage');
  except
    on E: Exception do
    begin
      Log.LogError(Format('SoundStage HTTP API failed to start on port %d: %s', [FPort, E.Message]), 'SoundStage');
      if Assigned(FServer) then
      begin
        FServer.Free;
        FServer := nil;
      end;
      FEnabled := False;
    end;
  end;
end;

procedure TSoundStageServer.Stop;
var
  List: TList;
  I: Integer;
  Cmd: TSoundStageCmd;
  Pending: array of TSoundStageCmd;
  N: Integer;
  WakeSocket: TSocket;
  Addr: TInetSockAddr;
  WaitMs: Integer;
begin
  FEnabled := False;

  if Assigned(FServer) then
  begin
    try
      FServer.Active := False;
    except
      on E: Exception do
        Log.LogError('SoundStage HTTP API stop: ' + E.Message, 'SoundStage');
    end;
  end;

  if Assigned(FListener) then
  begin
    // Active := False alone does not reliably interrupt the listener thread's
    // blocking accept() call under FPC. Wake it by opening a loopback
    // connection to our own port; accept() returns, Execute sees Active=False
    // and returns, WaitFor unblocks.
    try
      WakeSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
      if WakeSocket >= 0 then
      begin
        FillChar(Addr, SizeOf(Addr), 0);
        Addr.sin_family := AF_INET;
        Addr.sin_port := htons(FPort);
        Addr.sin_addr.s_addr := htonl($7F000001); // 127.0.0.1
        fpConnect(WakeSocket, @Addr, SizeOf(Addr));
        CloseSocket(WakeSocket);
      end;
    except
      // Best-effort wake; listener may already be gone.
    end;

    // Poll for listener exit up to 2 s. If it hasn't exited by then we're
    // stuck — detach so USDX's shutdown can still complete. Acceptable at
    // process teardown since the kernel will reap everything on _exit.
    WaitMs := 0;
    while (not FListener.Finished) and (WaitMs < 2000) do
    begin
      Sleep(50);
      Inc(WaitMs, 50);
    end;
    if FListener.Finished then
    begin
      FListener.WaitFor;
      FreeAndNil(FListener);
    end
    else
    begin
      Log.LogError('SoundStage listener did not exit within 2s; detaching', 'SoundStage');
      FListener := nil;
    end;
  end;

  if Assigned(FServer) then
    FreeAndNil(FServer);

  // Fail any commands still in the queue so waiting handler threads unblock.
  N := 0;
  SetLength(Pending, 0);
  List := FQueue.LockList;
  try
    for I := 0 to List.Count - 1 do
    begin
      Cmd := TSoundStageCmd(List[I]);
      Cmd.ReplyStatus := 503;
      Cmd.ReplyJSON := '{"error":"shutting down"}';
      SetLength(Pending, N + 1);
      Pending[N] := Cmd;
      Inc(N);
    end;
    List.Clear;
  finally
    FQueue.UnlockList;
  end;
  for I := 0 to High(Pending) do
  begin
    Pending[I].ReplyEvent.SetEvent;
    Pending[I].Release;
  end;
end;

function TSoundStageServer.Enqueue(Kind: TSoundStageCmdKind; TimeoutMs: Cardinal): TSoundStageCmd;
var
  List: TList;
begin
  Result := TSoundStageCmd.Create(Kind);
  List := FQueue.LockList;
  try
    List.Add(Result);
  finally
    FQueue.UnlockList;
  end;
  Result.ReplyEvent.WaitFor(TimeoutMs);
end;

procedure TSoundStageServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Cmd: TSoundStageCmd;
  Kind: TSoundStageCmdKind;
  Timeout: Cardinal;
  Matched: Boolean;
  JSONData: TJSONData;
  Obj: TJSONObject;
  PlayersNode: TJSONData;
  PlayersVal: Integer;
  List: TList;
begin
  AResponse.ContentType := 'application/json';
  try
    // POST /play parses a body before enqueueing.
    if (ARequest.Method = 'POST') and (ARequest.URI = '/play') then
    begin
      JSONData := nil;
      try
        try
          JSONData := GetJSON(ARequest.Content);
        except
          on E: Exception do
          begin
            AResponse.Code := 400;
            AResponse.Content := '{"error":"malformed json"}';
            Exit;
          end;
        end;
        if not (JSONData is TJSONObject) then
        begin
          AResponse.Code := 400;
          AResponse.Content := '{"error":"body must be an object"}';
          Exit;
        end;
        Obj := TJSONObject(JSONData);
        // Validate before constructing Cmd — Cmd's refcount-2 lifecycle assumes
        // it reaches the drain queue, so an early Release would leak.
        if Assigned(Obj.Find('singer')) or Assigned(Obj.Find('singers')) then
        begin
          AResponse.Code := 400;
          AResponse.Content := '{"error":"legacy fields removed; use requester"}';
          Exit;
        end;
        if Obj.Get('requester', '') = '' then
        begin
          AResponse.Code := 400;
          AResponse.Content := '{"error":"requester required"}';
          Exit;
        end;
        PlayersVal := -1;
        PlayersNode := Obj.Find('players');
        if Assigned(PlayersNode) then
        begin
          if (PlayersNode.JSONType <> jtNumber) then
          begin
            AResponse.Code := 400;
            AResponse.Content := '{"error":"players must be 1 or 2"}';
            Exit;
          end;
          PlayersVal := PlayersNode.AsInteger;
          if (PlayersVal <> 1) and (PlayersVal <> 2) then
          begin
            AResponse.Code := 400;
            AResponse.Content := '{"error":"players must be 1 or 2"}';
            Exit;
          end;
        end;
        Cmd := TSoundStageCmd.Create(cmdPlay);
        Cmd.PlaySongId := Obj.Get('songId', -1);
        Cmd.PlayRequester := Obj.Get('requester', '');
        Cmd.PlayPlayers := PlayersVal;
      finally
        if Assigned(JSONData) then JSONData.Free;
      end;

      List := FQueue.LockList;
      try
        List.Add(Cmd);
      finally
        FQueue.UnlockList;
      end;
      Cmd.ReplyEvent.WaitFor(10000);

      try
        AResponse.Code := Cmd.ReplyStatus;
        AResponse.Content := Cmd.ReplyJSON;
      finally
        Cmd.Release;
      end;
      Exit;
    end;

    Matched := True;
    Timeout := 5000;
    if (ARequest.Method = 'GET') and (ARequest.URI = '/now-playing') then
      Kind := cmdNowPlaying
    else if (ARequest.Method = 'GET') and (ARequest.URI = '/songs') then
    begin
      Kind := cmdSongs;
      Timeout := 15000; // full song-list serialisation can be slow on Deck
    end
    else if (ARequest.Method = 'POST') and (ARequest.URI = '/pause') then
      Kind := cmdPause
    else if (ARequest.Method = 'POST') and (ARequest.URI = '/resume') then
      Kind := cmdResume
    else if (ARequest.Method = 'GET') and (ARequest.URI = '/debug/state') then
      Kind := cmdDebugState
    else
      Matched := False;

    if Matched then
    begin
      Cmd := Enqueue(Kind, Timeout);
      try
        AResponse.Code := Cmd.ReplyStatus;
        AResponse.Content := Cmd.ReplyJSON;
      finally
        Cmd.Release;
      end;
    end
    else
    begin
      AResponse.Code := 404;
      AResponse.Content := '{"error":"not found"}';
    end;
  except
    on E: Exception do
    begin
      AResponse.Code := 500;
      AResponse.Content := '{"error":"internal"}';
    end;
  end;
end;

// JSON-locale format settings: force '.' as decimal separator so the
// output is valid regardless of system locale.
var
  JsonFS: TFormatSettings;

function NowPlayingJson: UTF8String;
var
  SongId: Integer;
begin
  if (Display.CurrentScreen = @ScreenSing) and
     (not AudioPlayback.Finished) and
     (CatSongs.Selected >= 0) and
     (CatSongs.Selected < Length(CatSongs.Song)) then
  begin
    SongId := CatSongs.Selected;
    Result := Format(
      '{"title":%s,"artist":%s,"elapsed":%.3f,"duration":%.3f}',
      [JsonStr(CatSongs.Song[SongId].Title),
       JsonStr(CatSongs.Song[SongId].Artist),
       AudioPlayback.Position, AudioPlayback.Length],
      JsonFS);
    Exit;
  end;
  Result := 'null';
end;

// Loads default numbered avatars (game/avatars/1.png, 2.png, ...) for the first
// `Count` player slots. Falls back to the NoAvatarTexture placeholder tinted
// with the player's configured color — mirroring UScreenName.pas:381-395 so the
// HUD always has something non-blank to render.
procedure EnsureNoAvatarLoaded;
var
  J: Integer;
begin
  if NoAvatarTexture[1].TexNum <> 0 then Exit;
  for J := 1 to UIni.IMaxPlayerCount do
    NoAvatarTexture[J] := Texture.GetTexture(
      Skin.GetTextureFileName('NoAvatar_P' + IntToStr(J)),
      TEXTURE_TYPE_TRANSPARENT, $FFFFFF);
end;

procedure AssignDefaultAvatars(Count: Integer);
var
  I: Integer;
  AvatarPath: IPath;
  Col: TRGB;
begin
  for I := 1 to Count do
  begin
    AvatarPath := AvatarsPath.Append(Path(IntToStr(I) + '.png'));
    if (AvatarPath <> nil) and AvatarPath.IsFile() then
      AvatarPlayerTextures[I] := Texture.LoadTexture(AvatarPath)
    else
    begin
      EnsureNoAvatarLoaded;
      AvatarPlayerTextures[I] := NoAvatarTexture[I];
      Col := GetPlayerColor(Ini.PlayerColor[I - 1]);
      AvatarPlayerTextures[I].ColR := Col.R;
      AvatarPlayerTextures[I].ColG := Col.G;
      AvatarPlayerTextures[I].ColB := Col.B;
    end;
  end;
end;

function CurrentScreenName: UTF8String;
begin
  if Display.CurrentScreen = nil then
    Result := 'nil'
  else if Display.CurrentScreen = @ScreenSing then
    Result := 'ScreenSing'
  else if Display.CurrentScreen = @ScreenScore then
    Result := 'ScreenScore'
  else if Display.CurrentScreen = @ScreenMain then
    Result := 'ScreenMain'
  else if Display.CurrentScreen = @ScreenNextUp then
    Result := 'ScreenNextUp'
  else
    Result := 'other';
end;

function DebugStateJson: UTF8String;
var
  I: Integer;
  First: Boolean;
begin
  Result := '{';
  Result := Result + '"screen":' + JsonStr(CurrentScreenName);
  Result := Result + ',"iniPlayers":' + IntToStr(Ini.Players);
  Result := Result + ',"playersPlay":' + IntToStr(PlayersPlay);
  Result := Result + ',"audioFinished":' + LowerCase(BoolToStr(AudioPlayback.Finished, true));

  Result := Result + ',"iniName":[';
  First := True;
  for I := 0 to High(Ini.Name) do
  begin
    if not First then Result := Result + ',';
    First := False;
    Result := Result + JsonStr(Ini.Name[I]);
  end;
  Result := Result + ']';

  Result := Result + ',"player":[';
  First := True;
  for I := 0 to High(Player) do
  begin
    if not First then Result := Result + ',';
    First := False;
    Result := Result + '{"name":' + JsonStr(Player[I].Name) +
                       ',"level":' + IntToStr(Player[I].Level) + '}';
  end;
  Result := Result + ']';

  Result := Result + ',"screenSingPlayerNames":[';
  First := True;
  if Assigned(ScreenSing) then
  begin
    for I := 1 to High(ScreenSing.PlayerNames) do
    begin
      if not First then Result := Result + ',';
      First := False;
      Result := Result + JsonStr(ScreenSing.PlayerNames[I]);
    end;
  end;
  Result := Result + ']';

  Result := Result + ',"currentSong":';
  if (CatSongs.Selected >= 0) and (CatSongs.Selected < Length(CatSongs.Song)) then
    Result := Result + '{"id":' + IntToStr(CatSongs.Selected) +
                       ',"title":' + JsonStr(CatSongs.Song[CatSongs.Selected].Title) +
                       ',"artist":' + JsonStr(CatSongs.Song[CatSongs.Selected].Artist) + '}'
  else
    Result := Result + 'null';

  Result := Result + '}';
end;

function SongsJson: UTF8String;
var
  J: Integer;
  First: Boolean;
begin
  Result := '[';
  First := True;
  for J := 0 to High(CatSongs.Song) do
  begin
    if not First then
      Result := Result + ',';
    First := False;
    Result := Result + '{"id":' + IntToStr(J) +
      ',"title":' + JsonStr(CatSongs.Song[J].Title) +
      ',"artist":' + JsonStr(CatSongs.Song[J].Artist) + '}';
  end;
  Result := Result + ']';
end;

// Drain-time handler for POST /play. Runs on the main thread, so direct
// access to CatSongs/Ini/Display/ScreenSing is safe.
procedure HandlePlayCommand(Cmd: TSoundStageCmd);
var
  SongId: Integer;
begin
  SongId := Cmd.PlaySongId;

  // Resolve songId; if out of range, ask CatSongs to rescan and retry once.
  if (SongId < 0) or (SongId >= Length(CatSongs.Song)) then
  begin
    Log.LogStatus(Format('Play: songId %d not in CatSongs (len %d), refreshing',
      [SongId, Length(CatSongs.Song)]), 'SoundStage');
    CatSongs.Refresh;
    if (SongId < 0) or (SongId >= Length(CatSongs.Song)) then
    begin
      Cmd.ReplyStatus := 404;
      Cmd.ReplyJSON := '{"error":"song not found"}';
      Exit;
    end;
  end;

  // Reject mid-song — Go owns the queue; mid-ScreenSing /play is a Go bug.
  if Display.CurrentScreen = @ScreenSing then
  begin
    Cmd.ReplyStatus := 409;
    Cmd.ReplyJSON := '{"error":"song in progress"}';
    Exit;
  end;

  if Display.CurrentScreen = @ScreenScore then
  begin
    // Mid-session handoff: player count is session-locked (already in
    // Ini.Players). Only the requester changes round-to-round; Player 2 is
    // a fixed literal, set once at session start. ScreenSing already exists
    // with the correct 2P/1P layout — cache on ScreenNextUp and let StartNow
    // update Player[].Name + ScreenSing.PlayerNames. Avatars stay as-is.
    if not Assigned(ScreenNextUp) then
      ScreenNextUp := TScreenNextUp.Create;
    ScreenNextUp.PendingSongId    := SongId;
    ScreenNextUp.PendingRequester := Cmd.PlayRequester;
    ScreenNextUp.PendingIs2P      := (Ini.Players = 1);  // Ini.Players is an IPlayersVals index; 1 → 2 players
    ScreenNextUp.PendingTitle     := CatSongs.Song[SongId].Title;
    ScreenNextUp.PendingArtist    := CatSongs.Song[SongId].Artist;
    Display.FadeTo(@ScreenNextUp);
  end
  else
  begin
    // First /play of a session (ScreenMain or similar non-Sing/non-Score):
    // lock the player count and mirror UScreenName.pas:362-417. ScreenSing
    // and ScreenScore must be (re)created AFTER Player/Ini/avatar state is
    // set, because TScreenSingView.Create snapshots Player[].Name into
    // ScreenSing.PlayerNames (UScreenSingView.pas:551) and AvatarPlayerTextures
    // into each Static's Texture (UScreenSingView.pas:665). Updating those
    // globals after construction doesn't propagate.
    SoundLib.PauseBgMusic;
    CatSongs.Selected := SongId;
    if Cmd.PlayPlayers = 2 then
    begin
      Ini.Players := 1;        // IPlayersVals[1] = 2
      PlayersPlay := 2;
      Ini.Name[0] := Cmd.PlayRequester;
      Ini.Name[1] := 'Player 2';
    end
    else
    begin
      Ini.Players := 0;        // IPlayersVals[0] = 1
      PlayersPlay := 1;
      Ini.Name[0] := Cmd.PlayRequester;
    end;
    SetLength(Player, PlayersPlay);
    Player[0].Name  := Ini.Name[0];
    Player[0].Level := Ini.PlayerLevel[0];
    if PlayersPlay >= 2 then
    begin
      Player[1].Name  := Ini.Name[1];
      Player[1].Level := Ini.PlayerLevel[1];
    end;
    AssignDefaultAvatars(PlayersPlay);
    LoadPlayersColors;
    Theme.ThemeScoreLoad;

    // (Re)create ScreenSing/ScreenScore so their constructors capture the
    // state we just set. Safe because CurrentScreen is ScreenMain here, not
    // either of the screens we're freeing. Mirrors UScreenName.pas:410-414.
    if Assigned(ScreenSing)  then FreeAndNil(ScreenSing);
    if Assigned(ScreenScore) then FreeAndNil(ScreenScore);
    TScreenSingController.Create;   // self-assigns ScreenSing := Self
    ScreenScore := TScreenScore.Create;
    if not Assigned(ScreenNextUp) then
      ScreenNextUp := TScreenNextUp.Create;

    Display.FadeTo(@ScreenSing);
  end;

  Cmd.ReplyStatus := 200;
  Cmd.ReplyJSON := '{"status":"playing"}';
end;

procedure TSoundStageServer.Drain;
var
  List: TList;
  I: Integer;
  Cmd: TSoundStageCmd;
  Batch: array of TSoundStageCmd;
  N: Integer;
begin
  if not FEnabled then Exit;

  N := 0;
  SetLength(Batch, 0);
  List := FQueue.LockList;
  try
    if List.Count = 0 then Exit;
    SetLength(Batch, List.Count);
    for I := 0 to List.Count - 1 do
      Batch[I] := TSoundStageCmd(List[I]);
    N := List.Count;
    List.Clear;
  finally
    FQueue.UnlockList;
  end;

  for I := 0 to N - 1 do
  begin
    Cmd := Batch[I];
    try
      case Cmd.Kind of
        cmdNowPlaying:
          begin
            Cmd.ReplyJSON := NowPlayingJson;
            Cmd.ReplyStatus := 200;
          end;
        cmdSongs:
          begin
            Cmd.ReplyJSON := SongsJson;
            Cmd.ReplyStatus := 200;
          end;
        cmdPause:
          begin
            if AudioPlayback.Finished then
            begin
              Cmd.ReplyStatus := 409;
              Cmd.ReplyJSON := '{"error":"not playing"}';
            end
            else
            begin
              AudioPlayback.Pause;
              Cmd.ReplyStatus := 200;
              Cmd.ReplyJSON := '{"status":"paused"}';
            end;
          end;
        cmdResume:
          begin
            if AudioPlayback.Finished then
            begin
              Cmd.ReplyStatus := 409;
              Cmd.ReplyJSON := '{"error":"nothing to resume"}';
            end
            else
            begin
              AudioPlayback.Play;
              Cmd.ReplyStatus := 200;
              Cmd.ReplyJSON := '{"status":"resumed"}';
            end;
          end;
        cmdPlay:
          HandlePlayCommand(Cmd);
        cmdDebugState:
          begin
            Cmd.ReplyJSON := DebugStateJson;
            Cmd.ReplyStatus := 200;
          end;
      end;
    except
      on E: Exception do
      begin
        Log.LogError('SoundStage drain handler: ' + E.Message, 'SoundStage');
        Cmd.ReplyStatus := 500;
        Cmd.ReplyJSON := '{"error":"internal"}';
      end;
    end;
    Cmd.ReplyEvent.SetEvent;
    Cmd.Release;
  end;
end;

initialization
  JsonFS := DefaultFormatSettings;
  JsonFS.DecimalSeparator := '.';
  JsonFS.ThousandSeparator := #0;

end.

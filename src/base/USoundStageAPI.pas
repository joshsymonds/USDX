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
  TSoundStageCmdKind = (cmdNowPlaying, cmdSongs, cmdPause, cmdResume, cmdQueue, cmdDebugState);

  // Process-lifetime pending song slot. Populated by POST /queue on any screen
  // except ScreenSing (409). Consumed by ScreenNextUp.StartNow on Enter.
  // Preserved across Esc cancels (user can return via Sing-button pull).
  // Active = false means the slot is empty — no queue.
  TQueuedSong = record
    Active:    boolean;
    SongId:    UTF8String;  // stable content-hash; 16-hex-char lowercase
    Requester: UTF8String;
    Is2P:      boolean;
    Title:     UTF8String;
    Artist:    UTF8String;
  end;

  TSoundStageCmd = class
  private
    FRefCount: integer;
  public
    Kind: TSoundStageCmdKind;
    ReplyEvent: TEvent;
    ReplyJSON: string;
    ReplyStatus: integer;
    // cmdQueue payload — parsed from request body on the handler thread,
    // consumed on the main thread by the drain handler.
    QueueSongId: UTF8String;  // stable content-hash (16 hex chars)
    QueueRequester: UTF8String;
    QueuePlayers: integer;  // 1 or 2; -1 = omitted (only honored on first /queue of session)
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
  QueuedSong: TQueuedSong;

implementation

uses
  fpjson,
  jsonparser,
  UDisplay,
  UGraphic,
  UIni,
  UNote,
  UScreenNextUp,
  USongs,
  UMusic,
  ULog;

// Minimal JSON string escaper. Handles JSON-required escapes plus ASCII
// control chars; UTF-8 continuation bytes (>= 0x80) pass through unchanged,
// producing valid JSON. Uses TStringBuilder to keep both JsonStr and the
// SongsJson hot path out of O(N^2) concat territory.
procedure AppendJsonStr(Sb: TStringBuilder; const S: UTF8String);
var
  I: Integer;
  C: AnsiChar;
begin
  Sb.Append('"');
  for I := 1 to System.Length(S) do
  begin
    C := S[I];
    case C of
      '"':  Sb.Append('\"');
      '\':  Sb.Append('\\');
      #8:   Sb.Append('\b');
      #9:   Sb.Append('\t');
      #10:  Sb.Append('\n');
      #12:  Sb.Append('\f');
      #13:  Sb.Append('\r');
    else
      if Ord(C) < $20 then
        Sb.Append(Format('\u%.4x', [Ord(C)]))
      else
        Sb.Append(C);
    end;
  end;
  Sb.Append('"');
end;

function JsonStr(const S: UTF8String): UTF8String;
var
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    AppendJsonStr(Sb, S);
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ TSoundStageCmd }

constructor TSoundStageCmd.Create(AKind: TSoundStageCmdKind);
begin
  inherited Create;
  FRefCount := 2;
  Kind := AKind;
  ReplyEvent := TEvent.Create(nil, True, False, '');
  // If the main thread fails to drain before WaitFor timeout, the handler
  // thread ships these defaults — better than an empty 500 body.
  ReplyJSON := '{"error":"timeout"}';
  ReplyStatus := 504;
  QueueSongId := '';
  QueueRequester := '';
  QueuePlayers := -1;
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
    // Note: FPC 3.2.2's TFPHTTPServer does not surface Address/ConnectionTimeout
    // as public properties (despite the base class having setters), so the
    // listener is always bound to all interfaces with no per-conn timeout.
    // OS-level firewalling is the recommended mitigation for roaming Decks.
    FListener := TSoundStageListener.Create(FServer);
    FEnabled := True;
    Log.LogStatus(Format('SoundStage HTTP API listening on port %d (all interfaces)', [FPort]), 'SoundStage');
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
  SongIdNode: TJSONData;
  SongIdStr: UTF8String;
  PlayersVal: Integer;
  List: TList;
begin
  AResponse.ContentType := 'application/json';
  try
    // POST /queue parses a body before enqueueing.
    if (ARequest.Method = 'POST') and (ARequest.URI = '/queue') then
    begin
      // Cap body size so a misbehaving or malicious client can't OOM USDX
      // by posting multi-megabyte payloads. 64 KB is ample for a 3-field JSON.
      if System.Length(ARequest.Content) > 65536 then
      begin
        AResponse.Code := 413;
        AResponse.Content := '{"error":"body too large"}';
        Exit;
      end;
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
        // songId must be a non-empty string (stable content hash). Integer
        // IDs are no longer accepted.
        SongIdNode := Obj.Find('songId');
        if (SongIdNode = nil) or (SongIdNode.JSONType <> jtString) then
        begin
          AResponse.Code := 400;
          AResponse.Content := '{"error":"songId required (string)"}';
          Exit;
        end;
        SongIdStr := SongIdNode.AsString;
        if SongIdStr = '' then
        begin
          AResponse.Code := 400;
          AResponse.Content := '{"error":"songId required (string)"}';
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
          // Must be a JSON number AND an integer (reject 1.5, strings, etc.).
          if (PlayersNode.JSONType <> jtNumber) or
             (TJSONNumber(PlayersNode).NumberType <> ntInteger) then
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
        Cmd := TSoundStageCmd.Create(cmdQueue);
        Cmd.QueueSongId := SongIdStr;
        Cmd.QueueRequester := Obj.Get('requester', '');
        Cmd.QueuePlayers := PlayersVal;
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
      Log.LogError('SoundStage HandleRequest: ' + E.Message, 'SoundStage');
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
  SongIdx: Integer;
begin
  if (Display.CurrentScreen = @ScreenSing) and
     (not AudioPlayback.Finished) and
     (CatSongs.Selected >= 0) and
     (CatSongs.Selected < Length(CatSongs.Song)) then
  begin
    SongIdx := CatSongs.Selected;
    Result := Format(
      '{"id":%s,"title":%s,"artist":%s,"elapsed":%.3f,"duration":%.3f}',
      [JsonStr(CatSongs.Song[SongIdx].ID),
       JsonStr(CatSongs.Song[SongIdx].Title),
       JsonStr(CatSongs.Song[SongIdx].Artist),
       AudioPlayback.Position, AudioPlayback.Length],
      JsonFS);
    Exit;
  end;
  Result := 'null';
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
    Result := Result + '{"id":' + JsonStr(CatSongs.Song[CatSongs.Selected].ID) +
                       ',"title":' + JsonStr(CatSongs.Song[CatSongs.Selected].Title) +
                       ',"artist":' + JsonStr(CatSongs.Song[CatSongs.Selected].Artist) + '}'
  else
    Result := Result + 'null';

  Result := Result + ',"queuedSong":';
  if QueuedSong.Active then
    Result := Result + '{"songId":' + JsonStr(QueuedSong.SongId) +
                       ',"requester":' + JsonStr(QueuedSong.Requester) +
                       ',"is2P":' + LowerCase(BoolToStr(QueuedSong.Is2P, true)) +
                       ',"title":' + JsonStr(QueuedSong.Title) +
                       ',"artist":' + JsonStr(QueuedSong.Artist) + '}'
  else
    Result := Result + 'null';

  Result := Result + '}';
end;

function SongsJson: UTF8String;
var
  Sb: TStringBuilder;
  J: Integer;
  First: Boolean;
begin
  // Preallocate for a large library — a 2KB initial capacity on the builder
  // avoids the first few growth reallocations. This path was O(N^2) under
  // `Result := Result + ...` and caused a visible frame hitch on the Deck
  // library (~900 songs); with the builder it's O(N) bytes written.
  Sb := TStringBuilder.Create(2048);
  try
    Sb.Append('[');
    First := True;
    for J := 0 to High(CatSongs.Song) do
    begin
      if CatSongs.Song[J].Main then continue;  // skip category headers
      if not First then Sb.Append(',');
      First := False;
      Sb.Append('{"id":');
      AppendJsonStr(Sb, CatSongs.Song[J].ID);
      Sb.Append(',"title":');
      AppendJsonStr(Sb, CatSongs.Song[J].Title);
      Sb.Append(',"artist":');
      AppendJsonStr(Sb, CatSongs.Song[J].Artist);
      Sb.Append(',"duet":');
      if CatSongs.Song[J].isDuet then Sb.Append('true') else Sb.Append('false');
      Sb.Append('}');
    end;
    Sb.Append(']');
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

// Drain-time handler for POST /queue. Runs on the main thread, so direct
// access to CatSongs/Ini/Display/ScreenSing is safe.
procedure HandleQueueCommand(Cmd: TSoundStageCmd);
var
  SongIdx: Integer;
begin
  // Content-hash lookup. Stable across CatSongs.Refresh, so no retry dance.
  SongIdx := CatSongs.FindById(Cmd.QueueSongId);
  if SongIdx = -1 then
  begin
    Cmd.ReplyStatus := 404;
    Cmd.ReplyJSON := '{"error":"unknown songId"}';
    Exit;
  end;

  // Reject mid-song — Go owns the queue; mid-ScreenSing /queue is a Go bug.
  if Display.CurrentScreen = @ScreenSing then
  begin
    Cmd.ReplyStatus := 409;
    Cmd.ReplyJSON := '{"error":"song in progress"}';
    Exit;
  end;

  // Pull-model queue semantics:
  //   - Writes QueuedSong unconditionally (newest wins, staged until consumed).
  //   - From ScreenScore: push to handoff immediately (mid-session in motion).
  //   - From ScreenMain or any other non-Sing screen: stage only; the user
  //     pulls via the Sing button which diverts to ScreenNextUp.
  // All session-setup work (Ini.Players, SetLength(Player), avatars, theme,
  // ScreenSing/Score recreation) happens in ScreenNextUp.StartNow on Enter.

  EnsureScreenNextUp;

  QueuedSong.Active    := true;
  QueuedSong.SongId    := Cmd.QueueSongId;  // store the stable hash, not the index
  QueuedSong.Requester := Cmd.QueueRequester;
  if Display.CurrentScreen = @ScreenScore then
    QueuedSong.Is2P := (Ini.Players = 1)     // session-locked — IPlayersVals[1] = 2
  else
    QueuedSong.Is2P := (Cmd.QueuePlayers = 2);
  QueuedSong.Title  := CatSongs.Song[SongIdx].Title;
  QueuedSong.Artist := CatSongs.Song[SongIdx].Artist;

  if Display.CurrentScreen = @ScreenScore then
    Display.FadeTo(@ScreenNextUp);

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
        cmdQueue:
          HandleQueueCommand(Cmd);
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
  Randomize;  // seed PRNG so AssignDefaultAvatars picks differently each process
  QueuedSong.Active := false;

end.

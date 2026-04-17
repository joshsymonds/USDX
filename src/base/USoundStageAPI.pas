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
  TSoundStageCmdKind = (cmdNowPlaying, cmdSongs, cmdPause, cmdResume);

  TSoundStageCmd = class
  private
    FRefCount: integer;
  public
    Kind: TSoundStageCmdKind;
    ReplyEvent: TEvent;
    ReplyJSON: string;
    ReplyStatus: integer;
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
  UDisplay,
  UGraphic,
  UScreenJukebox,
  USongs,
  UMusic,
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
begin
  AResponse.ContentType := 'application/json';
  try
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
  if (Display.CurrentScreen = @ScreenJukebox) and
     Assigned(ScreenJukebox) and
     (Length(ScreenJukebox.JukeboxSongsList) > 0) and
     (ScreenJukebox.CurrentSongList >= 0) and
     (ScreenJukebox.CurrentSongList < Length(ScreenJukebox.JukeboxSongsList)) and
     (not ScreenJukebox.FinishedMusic) then
  begin
    SongId := ScreenJukebox.JukeboxSongsList[ScreenJukebox.CurrentSongList];
    if (SongId >= 0) and (SongId < Length(CatSongs.Song)) then
    begin
      Result := Format(
        '{"title":%s,"artist":%s,"elapsed":%.3f,"duration":%.3f}',
        [JsonStr(CatSongs.Song[SongId].Title),
         JsonStr(CatSongs.Song[SongId].Artist),
         AudioPlayback.Position, AudioPlayback.Length],
        JsonFS);
      Exit;
    end;
  end;
  Result := 'null';
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

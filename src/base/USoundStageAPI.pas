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
  fphttpserver,
  httpdefs;

type
  TSoundStageCmdKind = (cmdNowPlaying);

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
  ULog;

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
    FListener.WaitFor;
    FreeAndNil(FListener);
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
begin
  AResponse.ContentType := 'application/json';
  try
    if (ARequest.Method = 'GET') and (ARequest.URI = '/now-playing') then
    begin
      Cmd := Enqueue(cmdNowPlaying, 5000);
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
    case Cmd.Kind of
      cmdNowPlaying:
        begin
          Cmd.ReplyJSON := 'null';
          Cmd.ReplyStatus := 200;
        end;
    end;
    Cmd.ReplyEvent.SetEvent;
    Cmd.Release;
  end;
end;

end.

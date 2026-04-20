{* UltraStar Deluxe — SoundStage Next-Up interstitial
 *
 * Displayed between songs when SoundStage's Go server dispatches the
 * next queued singer via POST /play while USDX is on ScreenScore.
 * Holds on screen indefinitely — Enter/Space applies the cached song
 * state and transitions to ScreenSing; Esc/Backspace cancels to
 * ScreenMain, ending the session. The indefinite hold is the whole
 * point: the real-life singers negotiate who takes the Player 2 slot.
 *
 * Pending* fields are populated by POST /play's drain handler BEFORE
 * FadeTo(@ScreenNextUp). State is applied in StartNow (on Enter), so
 * /now-playing during the handoff still reports the previous song
 * (or null when AudioPlayback.Finished).
 *}

unit UScreenNextUp;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  sdl2,
  SysUtils,
  UIni,
  UMenu,
  UMusic,
  UNote,
  UThemes,
  UUnicodeUtils;

type
  TScreenNextUp = class(TMenu)
  public
    // Pending song state, set by POST /play handler before FadeTo.
    PendingSongId:    integer;
    PendingRequester: UTF8String;   // Player 1 name for the upcoming song
    PendingIs2P:      boolean;      // true → session is 2-player
    PendingTitle:     UTF8String;
    PendingArtist:    UTF8String;

    // Text control indices
    HeaderIdx:  integer;
    TitleIdx:   integer;
    ArtistIdx:  integer;
    Player1Idx: integer;
    Player2Idx: integer;
    PromptIdx:  integer;

    Applied: boolean;   // StartNow idempotence guard across fade frames

    constructor Create; override;
    procedure OnShow; override;
    function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
  private
    procedure StartNow;
    procedure Cancel;
  end;

var
  ScreenNextUp: TScreenNextUp;

implementation

uses
  UCommon,
  UDisplay,
  UGraphic,
  UMenuBackgroundColor,
  UScreenSingController,
  USongs;

constructor TScreenNextUp.Create;
var
  BgCfg: TThemeBackground;
begin
  inherited Create;

  // Neutral dark background via glClearColor. We avoid LoadFromTheme here —
  // Loading's art is disorienting, and we don't want to re-use another
  // screen's busy background either. A plain color is the right level of
  // restraint for a handoff/waiting screen. Raw glBegin didn't render (outer
  // fade renderer's blend/matrix state), so we use USDX's own
  // TMenuBackgroundColor which wraps glClearColor.
  BgCfg.BGType := bgtColor;
  BgCfg.Color.R := 0.08;
  BgCfg.Color.G := 0.08;
  BgCfg.Color.B := 0.10;
  BgCfg.Tex := '';
  Background := TMenuBackgroundColor.Create(BgCfg);

  // Virtual canvas is 800x600. Font 0 = default proportional, style 0 = plain.
  HeaderIdx  := AddText(400,  80, 0, 0, 48, 1,    1,    1,    'Up Next');
  TitleIdx   := AddText(400, 200, 0, 0, 40, 1,    1,    1,    '');
  ArtistIdx  := AddText(400, 260, 0, 0, 30, 0.85, 0.85, 0.85, '');
  Player1Idx := AddText(400, 360, 0, 0, 36, 1,    1,    1,    '');
  Player2Idx := AddText(400, 410, 0, 0, 36, 1,    1,    1,    '');
  PromptIdx  := AddText(400, 520, 0, 0, 24, 0.7,  0.7,  0.7,  'Press Enter to start');

  PendingSongId    := -1;
  PendingRequester := '';
  PendingIs2P      := false;
  PendingTitle     := '';
  PendingArtist    := '';
  Applied          := false;
end;

procedure TScreenNextUp.OnShow;
var
  RequesterLabel: UTF8String;
begin
  inherited;
  Applied := false;

  if PendingRequester <> '' then
    RequesterLabel := PendingRequester
  else
    RequesterLabel := 'Next singer';

  Text[TitleIdx].Text   := PendingTitle;
  Text[ArtistIdx].Text  := PendingArtist;
  Text[Player1Idx].Text := 'Player 1: ' + RequesterLabel;

  // Hide Player 2 row when the session is 1-player — the epic only shows it
  // in 2P mode where the literal "Player 2" slot exists.
  Text[Player2Idx].Visible := PendingIs2P;
  if PendingIs2P then
    Text[Player2Idx].Text := 'Player 2: Player 2';
end;

function TScreenNextUp.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
begin
  Result := true;
  if not PressedDown then Exit;
  case PressedKey of
    SDLK_RETURN, SDLK_SPACE:
      StartNow;
    SDLK_ESCAPE, SDLK_BACKSPACE:
      Cancel;
  end;
end;

procedure TScreenNextUp.StartNow;
begin
  if Applied then Exit;
  Applied := true;

  // Apply cached state right before transitioning so /now-playing during the
  // handoff still reports the previous (or null) song. Player count was locked
  // at session start and is not touched here — only the Name slots change
  // round-to-round. Ini.Name[] is config, Player[].Name is runtime, and
  // ScreenSing.PlayerNames[] is the HUD snapshot (UScreenSingView.pas:551).
  CatSongs.Selected := PendingSongId;
  Ini.Name[0] := PendingRequester;
  if High(Player) >= 0 then
    Player[0].Name := PendingRequester;
  if PendingIs2P then
  begin
    Ini.Name[1] := 'Player 2';
    if High(Player) >= 1 then
      Player[1].Name := 'Player 2';
  end;

  if not Assigned(ScreenSing) then
    TScreenSingController.Create;

  ScreenSing.PlayerNames[1] := Ini.Name[0];
  if PendingIs2P then
    ScreenSing.PlayerNames[2] := Ini.Name[1];

  FadeTo(@ScreenSing);
end;

procedure TScreenNextUp.Cancel;
begin
  Applied := true;
  FadeTo(@ScreenMain);
end;

end.

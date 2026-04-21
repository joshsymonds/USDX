{* UltraStar Deluxe — SoundStage Next-Up interstitial
 *
 * Displayed when SoundStage's Go server queues a song. Reads from the
 * process-lifetime USoundStageAPI.QueuedSong slot — Enter/Space applies
 * + clears the slot and transitions to ScreenSing; Esc/Backspace cancels
 * to ScreenMain while PRESERVING the slot so the user can retry via
 * main-menu pull. The indefinite hold is the whole point: the real-life
 * singers negotiate who takes the Player 2 slot.
 *
 * /now-playing during the handoff still reports the previous (or null)
 * song — QueuedSong is not applied until StartNow.
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
  UMenuBackgroundTexture,
  UScreenSingController,
  USongs,
  USoundStageAPI;

constructor TScreenNextUp.Create;
var
  BgCfg: TThemeBackground;
begin
  inherited Create;

  // Custom handoff background image. Skin.GetTextureFileName resolves the
  // logical name NextUpBG (registered in Blue.ini / Winter.ini) to
  // [bg-nextup].png. TMenuBackgroundTexture stretches it across the 800x600
  // virtual canvas via glBegin(GL_QUADS). Falls back to a dark color if the
  // texture fails to load (e.g. file missing on a different skin).
  try
    BgCfg.BGType := bgtTexture;
    BgCfg.Color.R := 1.0;
    BgCfg.Color.G := 1.0;
    BgCfg.Color.B := 1.0;
    BgCfg.Tex := 'NextUpBG';
    Background := TMenuBackgroundTexture.Create(BgCfg);
  except
    BgCfg.BGType := bgtColor;
    BgCfg.Color.R := 0.08;
    BgCfg.Color.G := 0.08;
    BgCfg.Color.B := 0.10;
    BgCfg.Tex := '';
    Background := TMenuBackgroundColor.Create(BgCfg);
  end;

  // Virtual canvas is 800x600. Font 0 = default proportional, style 0 = plain.
  HeaderIdx  := AddText(400,  80, 0, 0, 48, 1,    1,    1,    'Up Next');
  TitleIdx   := AddText(400, 200, 0, 0, 40, 1,    1,    1,    '');
  ArtistIdx  := AddText(400, 260, 0, 0, 30, 0.85, 0.85, 0.85, '');
  Player1Idx := AddText(400, 360, 0, 0, 36, 1,    1,    1,    '');
  Player2Idx := AddText(400, 410, 0, 0, 36, 1,    1,    1,    '');
  PromptIdx  := AddText(400, 520, 0, 0, 24, 0.7,  0.7,  0.7,  'Press Enter to start');

  Applied := false;
end;

procedure TScreenNextUp.OnShow;
var
  RequesterLabel: UTF8String;
begin
  inherited;
  Applied := false;

  // If we're arriving from ScreenMain (pull path), its BG music is still
  // running on a separate AudioPlayback stream. From ScreenScore (push path)
  // it's already paused. PauseBgMusic is idempotent, so call unconditionally.
  SoundLib.PauseBgMusic;

  if QueuedSong.Active and (QueuedSong.Requester <> '') then
    RequesterLabel := QueuedSong.Requester
  else
    RequesterLabel := 'Next singer';

  Text[TitleIdx].Text   := QueuedSong.Title;
  Text[ArtistIdx].Text  := QueuedSong.Artist;
  Text[Player1Idx].Text := 'Player 1: ' + RequesterLabel;

  // Hide Player 2 row when the session is 1-player — the epic only shows it
  // in 2P mode where the literal "Player 2" slot exists.
  Text[Player2Idx].Visible := QueuedSong.Active and QueuedSong.Is2P;
  if QueuedSong.Is2P then
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
  if not QueuedSong.Active then Exit;   // nothing to apply — shouldn't happen, defensive

  // Apply cached state right before transitioning so /now-playing during the
  // handoff still reports the previous (or null) song. Player count was locked
  // at session start and is not touched here — only the Name slots change
  // round-to-round. Ini.Name[] is config, Player[].Name is runtime, and
  // ScreenSing.PlayerNames[] is the HUD snapshot (UScreenSingView.pas:551).
  CatSongs.Selected := QueuedSong.SongId;
  Ini.Name[0] := QueuedSong.Requester;
  if High(Player) >= 0 then
    Player[0].Name := QueuedSong.Requester;
  if QueuedSong.Is2P then
  begin
    Ini.Name[1] := 'Player 2';
    if High(Player) >= 1 then
      Player[1].Name := 'Player 2';
  end;

  if not Assigned(ScreenSing) then
    TScreenSingController.Create;

  ScreenSing.PlayerNames[1] := Ini.Name[0];
  if QueuedSong.Is2P then
    ScreenSing.PlayerNames[2] := Ini.Name[1];

  // Consume the queue slot — this was the "next up" song, now it's started.
  QueuedSong.Active := false;

  FadeTo(@ScreenSing);
end;

procedure TScreenNextUp.Cancel;
begin
  Applied := true;
  // ScreenMain.OnShow starts BG music via PlaySound, which layers ON TOP of
  // any stream still open on AudioPlayback (e.g., the previous song from
  // ScreenSing — its stream survives the Sing→Score→NextUp transitions).
  // Stop explicitly so main menu is silent-then-BG, not dueling audio.
  AudioPlayback.Stop;
  // QueuedSong is NOT cleared — user can return via Sing-button pull and
  // resume this same handoff.
  FadeTo(@ScreenMain);
end;

end.

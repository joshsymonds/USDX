{* UltraStar Deluxe — SoundStage Next-Up interstitial
 *
 * Displayed between songs when SoundStage's Go server dispatches the
 * next queued singer via POST /play while USDX is on ScreenScore.
 * Shows upcoming singer name(s), song title, artist, and a 10-second
 * countdown. On expiry, auto-transitions to ScreenSing with the cached
 * song state. Enter/Space skips countdown; Esc cancels to ScreenMain.
 *
 * Pending* fields are populated by the POST /play drain handler BEFORE
 * FadeTo(@ScreenNextUp) is called. State is only applied when the
 * interstitial actually expires, so a /now-playing poll during the
 * countdown sees consistent "just finished" data (not the new song).
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
    PendingSongId:     integer;
    PendingRequester:  UTF8String;   // Player 1 name for the upcoming song
    PendingIs2P:       boolean;      // true → session is 2-player (Player 2 is literal)
    PendingTitle:      UTF8String;
    PendingArtist:     UTF8String;

    // Text control indices
    SingersIdx:   integer;
    TitleIdx:     integer;
    ArtistIdx:    integer;
    CountdownIdx: integer;

    // Timer
    StartTick:  Cardinal;
    Triggered:  boolean;   // guard: only StartNow once

    constructor Create; override;
    procedure OnShow; override;
    function Draw: boolean; override;
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
  UScreenSingController,
  USongs;

const
  CountdownMs = 10000;

constructor TScreenNextUp.Create;
begin
  inherited Create;

  // Borrow Theme.Loading for a guaranteed-working textured background.
  // Raw GL_QUADS didn't render in our test (likely blend/matrix state
  // from the outer fade renderer). LoadFromTheme goes through USDX's
  // proper Draw path so the BG is certain to appear.
  LoadFromTheme(Theme.Loading);

  // Four custom labels on top. USDX's virtual canvas is 800x600.
  // Font 0 = default proportional, style 0 = plain; RGB 0..1.
  SingersIdx   := AddText(400,  80, 0, 0, 48, 1, 1, 1, 'Up Next');
  TitleIdx     := AddText(400, 240, 0, 0, 40, 1, 1, 1, '');
  ArtistIdx    := AddText(400, 300, 0, 0, 30, 0.85, 0.85, 0.85, '');
  CountdownIdx := AddText(400, 420, 0, 0, 72, 1, 1, 1, '10');

  PendingSongId    := -1;
  PendingRequester := '';
  PendingIs2P      := false;
  PendingTitle     := '';
  PendingArtist    := '';
  Triggered        := false;
end;

procedure TScreenNextUp.OnShow;
var
  SingerLabel: UTF8String;
begin
  inherited;
  StartTick := SDL_GetTicks;
  Triggered := false;

  if PendingRequester <> '' then
    SingerLabel := PendingRequester
  else
    SingerLabel := 'Next singer';

  if (SingersIdx >= 0) and (SingersIdx < Length(Text)) then
    Text[SingersIdx].Text := SingerLabel;
  if (TitleIdx >= 0) and (TitleIdx < Length(Text)) then
    Text[TitleIdx].Text := PendingTitle;
  if (ArtistIdx >= 0) and (ArtistIdx < Length(Text)) then
    Text[ArtistIdx].Text := PendingArtist;
end;

function TScreenNextUp.Draw: boolean;
var
  Elapsed: Cardinal;
  Remaining: integer;
begin
  Elapsed := SDL_GetTicks - StartTick;
  if Elapsed >= CountdownMs then
  begin
    Remaining := 0;
    if not Triggered then
      StartNow;
  end
  else
    Remaining := (CountdownMs - Elapsed + 999) div 1000;

  if (CountdownIdx >= 0) and (CountdownIdx < Length(Text)) then
    Text[CountdownIdx].Text := IntToStr(Remaining);

  Result := inherited Draw;
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
  if Triggered then Exit;
  Triggered := true;

  // Apply cached state right before transitioning so /now-playing during
  // the handoff still reports the previous (or null) song. Player count
  // was locked at session start and is not touched here; only the Name
  // slots change round-to-round. Ini.Name[] is config, Player[].Name is
  // the runtime slot the HUD reads — both need the new requester.
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

  FadeTo(@ScreenSing);
end;

procedure TScreenNextUp.Cancel;
begin
  Triggered := true;
  FadeTo(@ScreenMain);
end;

end.

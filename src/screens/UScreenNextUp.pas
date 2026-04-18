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
  UUnicodeUtils;

type
  TScreenNextUp = class(TMenu)
  public
    // Pending song state, set by POST /play handler before FadeTo.
    PendingSongId:      integer;
    PendingPlayers:     integer;      // Ini.Players index
    PendingPlayersPlay: integer;      // PlayersPlay count
    PendingNames:       array of UTF8String;
    PendingTitle:       UTF8String;
    PendingArtist:      UTF8String;

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
    function JoinSingers: UTF8String;
  end;

var
  ScreenNextUp: TScreenNextUp;

implementation

uses
  UCommon,
  UDisplay,
  UGraphic,
  USongs;

const
  CountdownMs = 10000;

constructor TScreenNextUp.Create;
begin
  inherited Create;

  // Four hardcoded-position labels. USDX's virtual canvas is 800x600.
  // Font 0 = default proportional, style 0 = plain, args after size are
  // RGB 0..1.
  SingersIdx   := AddText(400,  80, 0, 0, 48, 1, 1, 1, 'Up Next');
  TitleIdx     := AddText(400, 240, 0, 0, 40, 1, 1, 1, '');
  ArtistIdx    := AddText(400, 300, 0, 0, 30, 0.85, 0.85, 0.85, '');
  CountdownIdx := AddText(400, 420, 0, 0, 72, 1, 1, 1, '10');

  PendingSongId      := -1;
  PendingPlayers     := 0;
  PendingPlayersPlay := 1;
  SetLength(PendingNames, 0);
  PendingTitle  := '';
  PendingArtist := '';
  Triggered := false;
end;

function TScreenNextUp.JoinSingers: UTF8String;
var
  I: integer;
begin
  Result := '';
  for I := 0 to High(PendingNames) do
  begin
    if I > 0 then
      Result := Result + ' & ';
    Result := Result + PendingNames[I];
  end;
  if Result = '' then
    Result := 'Next singer';
end;

procedure TScreenNextUp.OnShow;
begin
  inherited;
  StartTick := SDL_GetTicks;
  Triggered := false;

  // Populate labels from pending state. AddText returns an index into
  // the inherited Text[] array.
  if (SingersIdx >= 0) and (SingersIdx < Length(Text)) then
    Text[SingersIdx].Text := JoinSingers;
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
var
  I: integer;
begin
  if Triggered then Exit;
  Triggered := true;

  // Apply the cached state to USDX globals right before transitioning.
  // Doing it here (not in POST /play's handler) means a /now-playing
  // poll during the countdown still reports the previous song or null,
  // not a song that hasn't started yet.
  CatSongs.Selected := PendingSongId;
  Ini.Players       := PendingPlayers;
  PlayersPlay       := PendingPlayersPlay;
  for I := 0 to High(PendingNames) do
    if I < Length(Ini.Name) then
      Ini.Name[I] := PendingNames[I];

  // ScreenSing/Score should already be instantiated (either by earlier
  // UI traversal or by the POST /play handler that led us here), but
  // be safe — create on demand.
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

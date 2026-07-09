{* UltraStar Deluxe — SoundStage Next-Up interstitial
 *
 * Displayed when SoundStage's Go server queues a song. Reads from the
 * process-lifetime USoundStageAPI.QueuedSong slot — Enter/Space applies
 * + clears the slot and transitions to ScreenSing; Esc/Backspace cancels
 * to ScreenMain while PRESERVING the slot so the user can retry via
 * main-menu pull. The indefinite hold is the whole point: the real-life
 * singers negotiate who takes the Player 2 slot.
 *
 * StartNow owns the full pre-Sing ritual (Ini.Players, SetLength(Player),
 * Player[].Name/Level, avatar textures, LoadPlayersColors, ThemeScoreLoad,
 * FreeAndNil+recreate ScreenSing/ScreenScore). HandleQueueCommand in the
 * HTTP layer is just a queue-writer; the heavy lifting all lands here so
 * both pull-from-Main and push-from-Score go through the same codepath.
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

// Lazy-creates ScreenNextUp. Single entry point used by both the HTTP /queue
// drain handler (USoundStageAPI.HandleQueueCommand) and the ScreenMain Sing
// button intercept (UScreenMain.TrySingFromQueue).
procedure EnsureScreenNextUp;

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
  UAvatars,
  UCommon,
  UDisplay,
  UFilesystem,
  UGraphic,
  ULog,
  UMenuBackground,
  UMenuBackgroundColor,
  UMenuBackgroundTexture,
  UPath,
  UPathUtils,
  UScreenScore,
  UScreenSingController,
  USkins,
  USongs,
  USoundStageAPI,
  UTexture;

procedure EnsureScreenNextUp;
begin
  if not Assigned(ScreenNextUp) then
    ScreenNextUp := TScreenNextUp.Create;
end;

// --- Default-avatar helpers (moved from USoundStageAPI; only needed here) ---

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

function ListPortraitAvatars: TPathDynArray;
var
  Iter: IFileIterator;
  FileInfo: TFileInfo;
  Len: Integer;
begin
  Result := nil;
  Iter := FileSystem.FileFind(AvatarsPath.Append('*.jpg'), 0);
  while Iter.HasNext do
  begin
    FileInfo := Iter.Next;
    Len := Length(Result);
    SetLength(Result, Len + 1);
    Result[Len] := AvatarsPath.Append(FileInfo.Name);
  end;
end;

// Pick `Count` distinct random avatars from the jpg pool and assign them to
// AvatarPlayerTextures. Falls back to tinted NoAvatarTexture per slot if the
// pool is empty or smaller than Count.
procedure AssignDefaultAvatars(Count: Integer);
var
  Portraits: TPathDynArray;
  I, J: Integer;
  Swap: IPath;
  Col: TRGB;
begin
  Portraits := ListPortraitAvatars;

  // Partial Fisher-Yates: shuffle the first min(Count, Length) entries.
  for I := 0 to Count - 1 do
  begin
    if I >= Length(Portraits) then Break;
    J := I + Random(Length(Portraits) - I);
    if J <> I then
    begin
      Swap := Portraits[I];
      Portraits[I] := Portraits[J];
      Portraits[J] := Swap;
    end;
  end;

  for I := 1 to Count do
  begin
    if I - 1 < Length(Portraits) then
      AvatarPlayerTextures[I] := Texture.LoadTexture(Portraits[I - 1])
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

// --- Screen lifecycle ---

constructor TScreenNextUp.Create;
var
  BgCfg: TThemeBackground;
begin
  inherited Create;

  // Custom handoff background image. Skin.GetTextureFileName resolves the
  // logical name NextUpBG (registered in Blue.ini / Winter.ini) to
  // [bg-nextup].png. Falls back to a dark neutral fill if the texture
  // fails to load.
  try
    BgCfg.BGType := bgtTexture;
    BgCfg.Color.R := 1.0;
    BgCfg.Color.G := 1.0;
    BgCfg.Color.B := 1.0;
    BgCfg.Tex := 'NextUpBG';
    Background := TMenuBackgroundTexture.Create(BgCfg);
  except
    // Narrow catch to the specific texture-load failure. Any other exception
    // (AV, out-of-memory, file-system error) surfaces via the default handler.
    on E: EMenuBackgroundError do
    begin
      BgCfg.BGType := bgtColor;
      BgCfg.Color.R := 0.08;
      BgCfg.Color.G := 0.08;
      BgCfg.Color.B := 0.10;
      BgCfg.Tex := '';
      Background := TMenuBackgroundColor.Create(BgCfg);
    end;
  end;

  // Align=1 centers each string on X=400, the middle of the 800-unit render
  // space. The Align-less AddText overload is left-aligned, which parked all
  // of this text in the right half of the screen.
  HeaderIdx  := AddText(400,  80, 0, 0, 0, 0, 48, 1,    1,    1,    1, 'Up Next',              false, 0, 0, false);
  TitleIdx   := AddText(400, 200, 0, 0, 0, 0, 40, 1,    1,    1,    1, '',                     false, 0, 0, false);
  ArtistIdx  := AddText(400, 260, 0, 0, 0, 0, 30, 0.85, 0.85, 0.85, 1, '',                     false, 0, 0, false);
  Player1Idx := AddText(400, 360, 0, 0, 0, 0, 36, 1,    1,    1,    1, '',                     false, 0, 0, false);
  Player2Idx := AddText(400, 410, 0, 0, 0, 0, 36, 1,    1,    1,    1, '',                     false, 0, 0, false);
  PromptIdx  := AddText(400, 520, 0, 0, 0, 0, 24, 0.7,  0.7,  0.7,  1, 'Press Enter to start', false, 0, 0, false);

  Applied := false;
end;

procedure TScreenNextUp.OnShow;
var
  RequesterLabel: UTF8String;
begin
  inherited;
  Applied := false;

  // Defensive bail: in the documented flow we're never shown with an empty
  // queue (ScreenMain pull gates on Active, ScreenScore push writes first),
  // but if some future path ever lands here empty, bounce back rather than
  // rendering a blank "Player 1: Next singer" screen.
  if not QueuedSong.Active then
  begin
    FadeTo(@ScreenMain);
    Exit;
  end;

  // Pull path from ScreenMain leaves BG music running; push path from Score
  // has it paused already. PauseBgMusic is idempotent.
  SoundLib.PauseBgMusic;

  if QueuedSong.Requester <> '' then
    RequesterLabel := QueuedSong.Requester
  else
    RequesterLabel := 'Next singer';

  Text[TitleIdx].Text   := QueuedSong.Title;
  Text[ArtistIdx].Text  := QueuedSong.Artist;
  Text[Player1Idx].Text := 'Player 1: ' + RequesterLabel;

  Text[Player2Idx].Visible := QueuedSong.Is2P;
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
var
  NewPlayersPlay: Integer;
  SongIdx: Integer;
begin
  if Applied then Exit;
  Applied := true;
  if not QueuedSong.Active then Exit;

  // Resolve the stable content hash to a current array index. If the song
  // is gone (file removed between stage and pull), drop the queue and bail.
  SongIdx := CatSongs.FindById(QueuedSong.SongId);
  if SongIdx = -1 then
  begin
    Log.LogError(Format('StartNow: queued songId %s not found, dropping',
      [QueuedSong.SongId]), 'SoundStage');
    QueuedSong.Active := false;
    FadeTo(@ScreenMain);
    Exit;
  end;

  // Full pre-Sing ritual — mirrors UScreenName.pas:362-417. Runs regardless
  // of push/pull entry path. For mid-session 2P-stays-2P the Ini writes are
  // effectively no-ops and the recreate is cheap enough that we don't branch.
  CatSongs.Selected := SongIdx;
  if QueuedSong.Is2P then
  begin
    Ini.Players := 1;        // IPlayersVals[1] = 2
    NewPlayersPlay := 2;
    Ini.Name[0] := QueuedSong.Requester;
    Ini.Name[1] := 'Player 2';
  end
  else
  begin
    Ini.Players := 0;        // IPlayersVals[0] = 1
    NewPlayersPlay := 1;
    Ini.Name[0] := QueuedSong.Requester;
  end;
  PlayersPlay := NewPlayersPlay;

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

  // Recreate ScreenSing and ScreenScore so their constructors capture the
  // Player[].Name and AvatarPlayerTextures[] snapshots we just established.
  // Safe: CurrentScreen is ScreenNextUp right now, not either of the screens
  // being freed. Mirrors UScreenName.pas:410-414.
  if Assigned(ScreenSing)  then FreeAndNil(ScreenSing);
  if Assigned(ScreenScore) then FreeAndNil(ScreenScore);
  TScreenSingController.Create;   // self-assigns ScreenSing := Self
  ScreenScore := TScreenScore.Create;

  QueuedSong.Active := false;     // consumed

  FadeTo(@ScreenSing);
end;

procedure TScreenNextUp.Cancel;
begin
  Applied := true;
  // Stop any stream the previous session left open; otherwise ScreenMain's
  // StartBgMusic stacks on top and both play simultaneously.
  AudioPlayback.Stop;
  // QueuedSong is NOT cleared — user can return via Sing-button pull.
  FadeTo(@ScreenMain);
end;

end.

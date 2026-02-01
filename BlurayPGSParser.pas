{*
 *  URUWorks Blu-ray PGS Parser
 *
 *  The contents of this file are used with permission, subject to
 *  the Mozilla Public License Version 2.0 (the "License"); you may
 *  not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.mozilla.org/MPL/2.0.html
 *
 *  Software distributed under the License is distributed on an
 *  "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
 *  implied. See the License for the specific language governing
 *  rights and limitations under the License.
 *
 *  Copyright (C) 2023-2024 URUWorks, uruworks@gmail.com.
 *
 *  INFO: https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/
 *
 *}

unit BlurayPGSParser;

{$I BlurayPGSParser.inc}

interface

uses
  Classes, SysUtils, FPImage, Math, BGRABitmap, BlurayPGSParser.Types;

type

  { TBlurayPGSParser }

  TBlurayPGSParser = class
  private
    FDSList: TDisplaySetList;
    FFileStream : TFileStream;
  public
    constructor Create(const AFileName: String = '');
    destructor Destroy; override;
    function Parse(const AFileName: String): Boolean;
    function GetBitmap(const DisplaySetIndex: Integer; const FullColor: Boolean = True): TBGRABitmap;
    function SaveBitmapToFile(const DisplaySetIndex: Integer; const FileName: String; const FullColor: Boolean = True): Boolean;
  private
    procedure Clear;
    function ParsePGS(const AStream: TStream; out APGS: TPGS): Boolean;
    function ParsePCS(const AStream: TStream; const APGS: TPGS): Boolean;
    function ParseWDS(const AStream: TStream; const APGS: TPGS): Boolean;
    function ParsePDS(const AStream: TStream; const APGS: TPGS): Boolean;
    function ParseODS(const AStream: TStream; const APGS: TPGS): Boolean;
    function ParseEND(const AStream: TStream; const APGS: TPGS): Boolean;
    function ParseSegment(const AStream: TStream; const APGS: TPGS): Boolean;
  published
    property DisplaySets: TDisplaySetList read FDSList write FDSList;
  end;

procedure WriteSUPDisplaySet(const AStream: TStream; const ACompositionNumber: Integer; const AInCue, AOutCue: Integer; const AImage: TBGRABitmap; const AVideoWidth, AVideoHeight: Integer; const AMargins: TRect; const AAlignment: TAlignment = taCenter; const AVerticalAlignment: TVerticalAlignment = taAlignBottom);

implementation

uses
  BlurayPGSParser.Utils;

// -----------------------------------------------------------------------------

{ TBlurayPGSParser }

// -----------------------------------------------------------------------------

constructor TBlurayPGSParser.Create(const AFileName: String = '');
begin
  FDSList := TDisplaySetList.Create;
  FFileStream := NIL;
  Parse(AFileName);
end;

// -----------------------------------------------------------------------------

destructor TBlurayPGSParser.Destroy;
begin
  Clear;
  FDSList.Free;
  if Assigned(FFileStream) then
    FFileStream.Free;

  inherited Destroy;
end;

// -----------------------------------------------------------------------------

procedure TBlurayPGSParser.Clear;
var
  i, c : Integer;
begin
  for i := 0 to FDSList.Count-1 do
  begin
    with FDSList[i]^ do
    begin
      for c := 0 to Length(Palettes)-1 do
        if Length(Palettes[c].Entries) > 0 then
          SetLength(Palettes[c].Entries, 0);

      SetLength(Pictures, 0);
      SetLength(Palettes, 0);
    end;
    Dispose(FDSList[i]);
  end;

  FDSList.Clear;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.Parse(const AFileName: String): Boolean;
var
  SegmentCount : Integer;
  PGS : TPGS;
  P : Int64;
begin
  Result := False;
  Clear;
  if AFileName.IsEmpty or not FileExists(AFileName) then Exit;

  if Assigned(FFileStream) then
    FFileStream.Free;

  FFileStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  SegmentCount := 0;
  while ParsePGS(FFileStream, PGS) do
  begin
    if (PGS.PG[0] <> mwP) and (pgs.PG[1] <> mwG) then
    begin
      {$IFDEF DEBUG}WriteLn('PGS not found at ', FFileStream.Position-SizeOf(PGS));{$ENDIF}
      Continue;
    end;

    {$IFDEF DEBUG}
    WriteLn(Format('Segment #: %d, Type: %d, Position: %d, Size: %d', [SegmentCount, PGS.SegmentType, FFileStream.Position-SizeOf(PGS), Read2Bytes(PGS.SegmentSize)]));
    {$ENDIF}

    P := FFileStream.Position;
    try
      ParseSegment(FFileStream, PGS);
    except
    end;
    if (P + Read2Bytes(PGS.SegmentSize)) <> FFileStream.Position then
      FFileStream.Position := P + Read2Bytes(PGS.SegmentSize);

    Inc(SegmentCount);
  end;
  {$IFDEF DEBUG}WriteLn('* DSCount: ', FDSList.Count);{$ENDIF}
  Result := FDSList.Count > 0;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParsePGS(const AStream: TStream; out APGS: TPGS): Boolean;
begin
  //WriteLn('* PGS');
  Result := AStream.Read(APGS, SizeOf(APGS)) = SizeOf(APGS);
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParsePCS(const AStream: TStream; const APGS: TPGS): Boolean;
var
  pcs : TPCS;
  co : TCO;
  ds : PDisplaySet;
  i : Byte;
begin
  //WriteLn('* PCS');
  ds := NIL;
  Result := AStream.Read(pcs, SizeOf(pcs)) = SizeOf(pcs);
  if Result then
  begin
    if pcs.CompositionState = csfEpochStart then
    begin
      New(ds);
      ds^.Text := '';
      ds^.Completed := False;
      ds^.InCue := TimestampToMs(Read4Bytes(APGS.PTS));
    end
    else
    begin
      ds := FDSList.Last;
      if (ds <> NIL) and not ds^.Completed then
      begin
        ds^.Completed := True;
        ds^.OutCue := TimestampToMs(Read4Bytes(APGS.PTS));
      end;
    end;

    if (pcs.PaletteUpdateFlag = pufTrue) and (ds <> NIL) then
      ds^.PaletteId := pcs.PaletteID;

    if pcs.NumberOfCompositionObjects > 0 then
    begin
      for i := 0 to pcs.NumberOfCompositionObjects-1 do
        AStream.Read(co, SizeOf(co));

      if ds <> NIL then
      begin
        ds^.IsForced := (co.ObjectCroppedFlag = ocfForceDisplay);
        ds^.X := Read2Bytes(co.ObjectHorizontalPosition);
        ds^.Y := Read2Bytes(co.ObjectVerticalPosition);
      end;
    end;

    if (ds <> NIL) and not ds^.Completed then
      FDSList.Add(ds);
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParseWDS(const AStream: TStream; const APGS: TPGS): Boolean;
var
  wds : TWDSNumberOfWindows;
  wdse : TWDSEntry;
  i : Byte;
begin
  //WriteLn('* WDS');
  Result := AStream.Read(wds, SizeOf(wds)) = SizeOf(wds);
  if Result and (wds > 0) then
    for i := 0 to wds-1 do
      AStream.Read(wdse, SizeOf(wdse));
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParsePDS(const AStream: TStream; const APGS: TPGS): Boolean;
var
  pds : TPDS;
  pdse : TPDSEntry;
  ds : PDisplaySet;
  pal : TPDSEntries;
  i : Byte;
  c : Integer;
  found : Boolean;
begin
  //WriteLn('* PDS');
  Result := AStream.Read(pds, SizeOf(pds)) = SizeOf(pds);
  ds := FDSList.Last;

  c := (Read2Bytes(APGS.SegmentSize) - SizeOf(pds)) div SizeOf(pdse);
  SetLength(pal, c);
  for i := 0 to c-1 do
    AStream.Read(pal[i], SizeOf(pdse));

  if (ds <> NIL) and (c > 0) then
  begin
    found := False;
    if Length(ds^.Palettes) > 0 then
    begin
      for i := 0 to Length(ds^.Palettes)-1 do
        if ds^.Palettes[i].ID = pds.PaletteID then
        begin
          found := True;
          Break;
        end;
    end;

    if not found then
    begin
      SetLength(ds^.Palettes, Length(ds^.Palettes)+1);
      with ds^.Palettes[Length(ds^.Palettes)-1] do
      begin
        ID := pds.PaletteID;
        Entries := pal;
      end;
    end
    else
      ds^.Palettes[i].Entries := pal;
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParseODS(const AStream: TStream; const APGS: TPGS): Boolean;
var
  ods : TODS;
  odse : TODSEntry;
  ds : PDisplaySet;
begin
  //WriteLn('* ODS');
  AStream.Read(ods, SizeOf(ods));
  AStream.Read(odse, SizeOf(odse));

  ds := FDSList.Last;
  if ds <> NIL then
  begin
    SetLength(ds^.Pictures, Length(ds^.Pictures)+1);
    with ds^.Pictures[Length(ds^.Pictures)-1] do
    begin
      Size := Read3Bytes(odse.ObjectDataLength)-4;
      Offset := AStream.Position;
    end;
    ds^.Width := Read2Bytes(odse.Width);
    ds^.Height := Read2Bytes(odse.Height);
  end
  else
    AStream.Position := AStream.Position + Read3Bytes(odse.ObjectDataLength)-4;

  Result := True;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParseEND(const AStream: TStream; const APGS: TPGS): Boolean;
begin
  //WriteLn('* END');
  Result := True;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParseSegment(const AStream: TStream; const APGS: TPGS): Boolean;
begin
  Result := False;
  case APGS.SegmentType of
    stfPDS: Result := ParsePDS(AStream, APGS);
    stfODS: Result := ParseODS(AStream, APGS);
    stfPCS: Result := ParsePCS(AStream, APGS);
    stfWDS: Result := ParseWDS(AStream, APGS);
    stfEND: Result := ParseEND(AStream, APGS);
  {$IFDEF DEBUG}
  else
    WriteLn('Unknown segment type');
  {$ENDIF}
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.GetBitmap(const DisplaySetIndex: Integer; const FullColor: Boolean = True): TBGRABitmap;
var
  ds : PDisplaySet;
  buf : TBytes;
  pal : TFPPalette = NIL;
  idx, c, i : Integer;
begin
  Result := NIL;
  if (FDSList.Count > 0) and InRange(DisplaySetIndex, 0, FDSList.Count-1) then
  begin
    ds := FDSList[DisplaySetIndex];
    if ds <> NIL then
    begin
      idx := Length(ds^.Palettes);
      if idx > 0 then
      begin
        with ds^.Palettes[idx-1] do
        begin
          c := Length(Entries);
          if c > 0 then
          begin
            pal := TFPPalette.Create(c);
            pal.Count := c;

            if pal.Count < 256 then
              pal.Count := 256;

            for i := 0 to pal.Count-1 do
              pal[i] := FPColor(0, 0, 0, 0);

            for i := 0 to c-1 do
            begin
              pal[Entries[i].PaletteEntryID] := YCbCrToFPColor(Entries[i].Luminance, Entries[i].ColorDifferenceBlue, Entries[i].ColorDifferenceRed, Entries[i].Transparency);
              //{$IFDEF DEBUG}WriteLn(i, ' ', Entries[i].PaletteEntryID, ': Y:', Entries[i].Luminance, ' Cb:', Entries[i].ColorDifferenceBlue, ' Cr:', Entries[i].ColorDifferenceRed, ' a:', Entries[i].Transparency);{$ENDIF}
            end;
          end;
        end;

        if pal = NIL then Exit;

        c := Length(ds^.Pictures);
        if c > 0 then
        begin
          SetLength(buf, ds^.Pictures[0].Size);
          FFileStream.Position := ds^.Pictures[0].Offset;
          FFileStream.Read(buf[0], Length(buf));
          if FullColor then
            Result := DecodeImage(buf, pal, ds^.Width, ds^.Height)
          else
            Result := DecodeImage2Colors(buf, pal, ds^.Width, ds^.Height);
          SetLength(buf, 0);
        end;
        pal.Free;
      end;
    end;
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.SaveBitmapToFile(const DisplaySetIndex: Integer; const FileName: String; const FullColor: Boolean = True): Boolean;
var
  bmp : TBGRABitmap;
begin
  Result := False;
  if FileName.IsEmpty then Exit;

  bmp := GetBitmap(DisplaySetIndex, FullColor);
  if Assigned(bmp) then
  try
    bmp.SaveToFile(FileName);
    Result := FileExists(FileName);
  finally
    bmp.Free;
  end;
end;

// -----------------------------------------------------------------------------

{ WriteSUPDisplaySet }

// -----------------------------------------------------------------------------

procedure WriteSUPDisplaySet(const AStream: TStream; const ACompositionNumber: Integer; const AInCue, AOutCue: Integer; const AImage: TBGRABitmap; const AVideoWidth, AVideoHeight: Integer; const AMargins: TRect; const AAlignment: TAlignment = taCenter; const AVerticalAlignment: TVerticalAlignment = taAlignBottom);
var
  pal : TFPPalette = NIL;
  rlebuf : TBytes;
  rlesize : Integer;
  x, it, ft : Integer;
  Xoffset, Yoffset : Integer;
  Y, Cb, Cr : Byte;
  pgs : TPGS;
  pcs : TPCS;
  wds : TWDSNumberOfWindows;
  wdse : TWDSEntry;
  pds : TPDS;
  pdse : TPDSEntry;
  ods : TODS;
  odse : TODSEntry;
  co  : TCO;
begin
  // Set 90kHz times
  it := MsToTimestamp(AInCue);
  ft := MsToTimestamp(AOutCue);

  // Get image buffer/pallete
  rlesize := EncodeImage(AImage, rlebuf, pal);

  // Prepare alignments
  case AAlignment of
    taLeftJustify : case AVerticalAlignment of
                      taVerticalCenter : begin
                                           Xoffset := AMargins.Left;
                                           Yoffset := (AVideoHeight - AImage.Height) div 2;
                                         end;
                      taAlignTop       : begin
                                           Xoffset := AMargins.Left;
                                           Yoffset := AMargins.Top;
                                         end;
                    else
                      Xoffset := AMargins.Left;
                      Yoffset := AVideoHeight - (AImage.Height + AMargins.Bottom);
                end;

    taCenter : case AVerticalAlignment of
                 taVerticalCenter : begin
                                      Xoffset := (AVideoWidth - AImage.Width) div 2;
                                      Yoffset := (AVideoHeight - AImage.Height) div 2;
                                    end;
                 taAlignTop       : begin
                                      Xoffset := (AVideoWidth - AImage.Width) div 2;
                                      Yoffset := AMargins.Top;
                                    end
                 else
                   Xoffset := (AVideoWidth - AImage.Width) div 2;
                   Yoffset := AVideoHeight - (AImage.Height + AMargins.Bottom);
                 end;

    taRightJustify : case AVerticalAlignment of
                       taVerticalCenter : begin
                                            Xoffset := AVideoWidth - AImage.Width - AMargins.Right;
                                            Yoffset := (AVideoHeight - AImage.Height) div 2;
                                          end;
                       taAlignTop       : begin
                                            Xoffset := AVideoWidth - AImage.Width - AMargins.Right;
                                            Yoffset := AMargins.Top;
                                          end;
                     else
                       Xoffset := AVideoWidth - AImage.Width - AMargins.Right;
                       Yoffset := AVideoHeight - (AImage.Height + AMargins.Bottom);
                     end;
  end;

  // PCS 'IT'
  with pgs do
  begin
    Set2Bytes(PG, mwPG);
    Set4Bytes(PTS, it);
    Set4Bytes(DTS, 0);
    SegmentType := stfPCS;
    Set2Bytes(SegmentSize, SizeOf(pcs) + SizeOf(co));
  end;
  AStream.Write(pgs, SizeOf(pgs));
  with pcs do
  begin
    Set2Bytes(VideoWidth, AVideoWidth);
    Set2Bytes(VideoHeight, AVideoHeight);
    FrameRate := frf23976;
    Set2Bytes(CompositionNumber, ACompositionNumber);
    CompositionState := csfEpochStart;
    PaletteUpdateFlag := pufFalse;
    PaletteID := 0;
    NumberOfCompositionObjects := 1;
  end;
  AStream.Write(pcs, SizeOf(pcs));
  // CO
  with co do
  begin
    Set2Bytes(ObjectID, 0);
    WindowID := 0;
    ObjectCroppedFlag := ocfOff;
    Set2Bytes(ObjectHorizontalPosition, Xoffset);
    Set2Bytes(ObjectVerticalPosition, Yoffset);
  end;
  AStream.Write(co, SizeOf(co));

  // WDS
  with pgs do
  begin
    SegmentType := stfWDS;
    Set2Bytes(SegmentSize, SizeOf(wds) + SizeOf(wdse));
  end;
  AStream.Write(pgs, SizeOf(pgs));
  wds := 1;
  AStream.Write(wds, SizeOf(wds));
  with wdse do
  begin
    WindowID := 0;
    Set2Bytes(WindowHorizontalPosition, Xoffset);
    Set2Bytes(WindowVerticalPosition, Yoffset);
    Set2Bytes(WindowWidth, AImage.Width);
    Set2Bytes(WindowHeight, AImage.Height);
  end;
  AStream.Write(wdse, SizeOf(wdse));

  // PDS
  with pgs do
  begin
    SegmentType := stfPDS;
    Set2Bytes(SegmentSize, SizeOf(pds) + (SizeOf(pdse) * pal.Count));
  end;
  AStream.Write(pgs, SizeOf(pgs));
  with pds do
  begin
    PaletteID := 0;
    PaletteVersionNumber := 0;
    AStream.Write(pds, SizeOf(pds));
    with pdse do
    begin
      for x := 0 to pal.Count-1 do
      begin
        PaletteEntryID := x;
        FPColorToYCbCr(pal.Color[x], Y, Cb, Cr);
        Luminance := Y;
        ColorDifferenceRed := Cr;
        ColorDifferenceBlue := Cb;
        Transparency := pal.Color[x].Alpha;
        AStream.Write(pdse, SizeOf(pdse));
      end;
    end;
    pal.Free;
  end;

  // ODS
  with pgs do
  begin
    SegmentType := stfODS;
    Set2Bytes(SegmentSize, SizeOf(ods) + SizeOf(odse) + rlesize);
  end;
  AStream.Write(pgs, SizeOf(pgs));
  with ods do
  begin
    Set2Bytes(ObjectID, 0);
    ObjectVersionNumber := 0;
    LastInSequenceFlag := lsfFirstAndLast;
  end;
  AStream.Write(ods, SizeOf(ods));
  with odse do
  begin
    Set3Bytes(ObjectDataLength, rlesize + 4);
    Set2Bytes(Width, AImage.Width);
    Set2Bytes(Height, AImage.Height);
  end;
  AStream.Write(odse, SizeOf(odse));
  AStream.Write(rlebuf[0], rlesize); // RLE Data
  SetLength(rlebuf, 0);

  // END 'IT'
  with pgs do
  begin
    SegmentType := stfEND;
    Set2Bytes(SegmentSize, 0);
  end;
  AStream.Write(pgs, SizeOf(pgs));

  // PCS 'FT'
  with pgs do
  begin
    Set4Bytes(PTS, ft);
    SegmentType := stfPCS;
    Set2Bytes(SegmentSize, SizeOf(pcs));
  end;
  AStream.Write(pgs, SizeOf(pgs));
  with pcs do
  begin
    Set2Bytes(CompositionNumber, ACompositionNumber + 1);
    CompositionState := csfNormal;
    NumberOfCompositionObjects := 0;
  end;
  AStream.Write(pcs, SizeOf(pcs));

  // WDS
  with pgs do
  begin
    SegmentType := stfWDS;
    Set2Bytes(SegmentSize, SizeOf(wds) + SizeOf(wdse));
  end;
  AStream.Write(pgs, SizeOf(pgs));
  AStream.Write(wds, SizeOf(wds));
  AStream.Write(wdse, SizeOf(wdse));

  // END 'FT'
  with pgs do
  begin
    SegmentType := stfEND;
    Set2Bytes(SegmentSize, 0);
  end;
  AStream.Write(pgs, SizeOf(pgs));
end;

// -----------------------------------------------------------------------------

end.


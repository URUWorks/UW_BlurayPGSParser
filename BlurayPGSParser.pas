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
 *  Copyright (C) 2023-2026 URUWorks, uruworks@gmail.com.
 *
 *  INFO: https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/
 *
 *}

unit BlurayPGSParser;

{$I BlurayPGSParser.inc}

interface

uses
  Classes, SysUtils, FPImage, Math, BGRABitmap, BGRABitmapTypes,
  Types, BlurayPGSParser.Types;

type

  { TBlurayPGSParser }

  TBlurayPGSParser = class
  private
    FDSList: TDisplaySetList;
    FFileStream : TFileStream;
    FLastError : String;
  public
    constructor Create(const AFileName: String = '');
    destructor Destroy; override;
    function Parse(const AFileName: String): Boolean;
    function GetBitmap(const DisplaySetIndex: Integer; const FullColor: Boolean = True): TBGRABitmap;
    function SaveBitmapToFile(const DisplaySetIndex: Integer; const FileName: String; const FullColor: Boolean = True): Boolean;
    property LastError: String read FLastError;
  private
    procedure Clear;
    function ReadPictureBuffer(const APicture: TPictureBuffer): TBytes;
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

procedure WriteSUPDisplaySet(const AStream: TStream; const ACompositionNumber: Integer; const AInCue, AOutCue: Int64; const AImage: TBGRABitmap; const AVideoWidth, AVideoHeight: Integer; const AMargins: TRect; const AAlignment: TAlignment = taCenter; const AVerticalAlignment: TVerticalAlignment = taAlignBottom; const AFrameRate: Byte = frf23976; const AMaxColors: Integer = 256; const ADithering: TDitheringAlgorithm = daFloydSteinberg);

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
  i, c: Integer;
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
  SegmentCount: Integer;
  PGS: TPGS;
  P: Int64;
begin
  Result := False;
  FLastError := '';
  Clear;
  if AFileName.IsEmpty then
  begin
    FLastError := 'Empty file name';
    Exit;
  end;
  if not FileExists(AFileName) then
  begin
    FLastError := 'File not found: ' + AFileName;
    Exit;
  end;

  if Assigned(FFileStream) then
    FFileStream.Free;

  FFileStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  SegmentCount := 0;
  while ParsePGS(FFileStream, PGS) do
  begin
    // A valid segment header starts with the 'PG' magic word. Either byte
    // being wrong means we're not aligned on a segment boundary
    if (PGS.PG[0] <> mwP) or (PGS.PG[1] <> mwG) then
    begin
      {$IFDEF DEBUG}WriteLn('PGS not found at ', FFileStream.Position-SizeOf(PGS));{$ENDIF}
      // Resync byte by byte instead of jumping a full header size, so we
      // don't skip past a valid header that happens to start 1-12 bytes in
      FFileStream.Position := FFileStream.Position - SizeOf(PGS) + 1;
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
  if not Result then
    FLastError := 'No display sets found (file may not be a valid PGS/SUP stream)';
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
  pcs: TPCS;
  co: TCO;
  coCropped: TCOCropped;
  ds: PDisplaySet;
  i: Byte;
  objId, objIdx, k: Integer;
begin
  //WriteLn('* PCS');
  ds := NIL;
  Result := AStream.Read(pcs, SizeOf(pcs)) = SizeOf(pcs);
  if Result then
  begin
    if pcs.CompositionState = csfEpochStart then
    begin
      New(ds);
      // Zero-initialize every plain field
      ds^.Text := '';
      ds^.Completed := False;
      ds^.IsForced := False;
      ds^.X := 0;
      ds^.Y := 0;
      ds^.Width := 0;
      ds^.Height := 0;
      ds^.PaletteId := 0;
      SetLength(ds^.Palettes, 0);
      SetLength(ds^.Pictures, 0);
      SetLength(ds^.Objects, 0);
      ds^.InCue := TimestampToMs(Read4Bytes(APGS.PTS));
      ds^.OutCue := ds^.InCue;
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
      begin
        AStream.Read(co, SizeOf(co));

        // Cropped composition objects carry an extra 8-byte crop rect that
        // must still be consumed from the stream
        if co.ObjectCroppedFlag = ocfForceDisplay then
          AStream.Read(coCropped, SizeOf(coCropped));

        if ds <> NIL then
        begin
          // Record every composition object (a display set can legally
          // contain more than one, e.g. two simultaneous subtitle regions)
          // instead of only keeping the last one read. An acquisition-point
          // PCS can update the position of an object ID that this same
          // display set already has, so look for an existing entry with
          // the same ObjectID and overwrite it in place rather than piling
          // up stale duplicates
          objId := Read2Bytes(co.ObjectID);
          objIdx := -1;
          for k := 0 to Length(ds^.Objects)-1 do
            if ds^.Objects[k].ObjectID = objId then
            begin
              objIdx := k;
              Break;
            end;

          if objIdx < 0 then
          begin
            SetLength(ds^.Objects, Length(ds^.Objects)+1);
            objIdx := High(ds^.Objects);
          end;

          with ds^.Objects[objIdx] do
          begin
            ObjectID := objId;
            X        := Read2Bytes(co.ObjectHorizontalPosition);
            Y        := Read2Bytes(co.ObjectVerticalPosition);
            IsForced := (co.ObjectCroppedFlag = ocfForceDisplay);
            // Each PCS restates this object from scratch, so HasCrop must
            // be refreshed every time (an object can switch between
            // cropped/uncropped across successive updates within the
            // same display set, e.g. a reveal/typewriter effect)
            HasCrop := IsForced;
            if HasCrop then
            begin
              CropX      := Read2Bytes(coCropped.ObjectCroppingHorizontalPosition);
              CropY      := Read2Bytes(coCropped.ObjectCroppingVerticalPosition);
              CropWidth  := Read2Bytes(coCropped.ObjectCroppingWidth);
              CropHeight := Read2Bytes(coCropped.ObjectCroppingHeightPosition);
            end
            else
            begin
              CropX := 0; CropY := 0; CropWidth := 0; CropHeight := 0;
            end;
          end;

          // Keep the legacy single X/Y/IsForced fields pointing at the
          // first object for backwards compatibility with existing callers
          if objIdx = 0 then
          begin
            ds^.IsForced := ds^.Objects[0].IsForced;
            ds^.X := ds^.Objects[0].X;
            ds^.Y := ds^.Objects[0].Y;
          end;
        end;
      end;
    end;

    if (ds <> NIL) and not ds^.Completed then
      FDSList.Add(ds);
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.ParseWDS(const AStream: TStream; const APGS: TPGS): Boolean;
var
  wds: TWDSNumberOfWindows;
  wdse: TWDSEntry;
  i: Byte;
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
  pds: TPDS;
  pdse: TPDSEntry;
  ds: PDisplaySet;
  pal: TPDSEntries;
  i: Byte;
  c: Integer;
  found: Boolean;
begin
  //WriteLn('* PDS');
  Result := AStream.Read(pds, SizeOf(pds)) = SizeOf(pds);
  if not Result then Exit;
  ds := FDSList.Last;

  c := (Read2Bytes(APGS.SegmentSize) - SizeOf(pds)) div SizeOf(pdse);
  // Defensive clamp: a palette can have at most 256 entries. A corrupt or
  // desynced SegmentSize could otherwise produce a huge/negative count
  // (and c-1 would overflow the Byte loop variable below)
  c := EnsureRange(c, 0, 256);
  SetLength(pal, c);

  if c > 0 then
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
  ods: TODS;
  odse: TODSEntry;
  ds: PDisplaySet;
  objId, picIdx, segSize, dataSize, i: Integer;
  isFirst: Boolean;
begin
  //WriteLn('* ODS');
  // Per spec, only the FIRST fragment of an object (LastInSequenceFlag has
  // the $80 bit set) carries the ObjectDataLength/Width/Height header.
  // Continuation fragments (large images split across several ODS
  // segments) are pure RLE bytes
  Result := AStream.Read(ods, SizeOf(ods)) = SizeOf(ods);
  if not Result then Exit;

  objId := Read2Bytes(ods.ObjectID);
  isFirst := (ods.LastInSequenceFlag and lsfFirst) <> 0;
  segSize := Read2Bytes(APGS.SegmentSize);
  ds := FDSList.Last;

  if isFirst then
  begin
    if AStream.Read(odse, SizeOf(odse)) <> SizeOf(odse) then Exit;
    dataSize := segSize - SizeOf(ods) - SizeOf(odse);

    if ds <> NIL then
    begin
      SetLength(ds^.Pictures, Length(ds^.Pictures)+1);
      picIdx := High(ds^.Pictures);
      with ds^.Pictures[picIdx] do
      begin
        ObjectID  := objId;
        Width     := Read2Bytes(odse.Width);
        Height    := Read2Bytes(odse.Height);
        TotalSize := Read3Bytes(odse.ObjectDataLength) - 4;
        Completed := (ods.LastInSequenceFlag and lsfLast) <> 0;
        SetLength(Chunks, 1);
        Chunks[0].Offset := AStream.Position;
        Chunks[0].Size   := dataSize;
      end;
      // Legacy convenience fields, kept for callers that only look at a
      // single image per display set
      ds^.Width := Read2Bytes(odse.Width);
      ds^.Height := Read2Bytes(odse.Height);
    end;
  end
  else
  begin
    dataSize := segSize - SizeOf(ods);

    if ds <> NIL then
    begin
      // Find the still-open picture with the same ObjectID to append to
      picIdx := -1;
      for i := High(ds^.Pictures) downto 0 do
        if (ds^.Pictures[i].ObjectID = objId) and not ds^.Pictures[i].Completed then
        begin
          picIdx := i;
          Break;
        end;

      if picIdx >= 0 then
        with ds^.Pictures[picIdx] do
        begin
          SetLength(Chunks, Length(Chunks)+1);
          Chunks[High(Chunks)].Offset := AStream.Position;
          Chunks[High(Chunks)].Size   := dataSize;
          if (ods.LastInSequenceFlag and lsfLast) <> 0 then
            Completed := True;
        end
      {$IFDEF DEBUG}
      else
        WriteLn('ODS continuation fragment with no matching open object: ', objId);
      {$ENDIF}
    end;
  end;
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

function TBlurayPGSParser.ReadPictureBuffer(const APicture: TPictureBuffer): TBytes;
// Reads every chunk of a (possibly fragmented) picture from the source
// file and concatenates them into a single RLE buffer
var
  j, total, bufPos : Integer;
begin
  total := 0;
  for j := 0 to High(APicture.Chunks) do
    Inc(total, APicture.Chunks[j].Size);

  SetLength(Result, total);
  bufPos := 0;
  for j := 0 to High(APicture.Chunks) do
  begin
    FFileStream.Position := APicture.Chunks[j].Offset;
    FFileStream.Read(Result[bufPos], APicture.Chunks[j].Size);
    Inc(bufPos, APicture.Chunks[j].Size);
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.GetBitmap(const DisplaySetIndex: Integer; const FullColor: Boolean = True): TBGRABitmap;
var
  ds: PDisplaySet;
  buf: TBytes;
  pal: TFPPalette = NIL;
  idx, c, i: Integer;
  minX, minY, maxX, maxY: Integer;
  drawX, drawY, drawW, drawH, srcX, srcY: Integer;
  picBmp: TBGRABitmap;
  partBmp: TBGRACustomBitmap;

  // Resolves where picture I actually ends up on screen: ADrawX/Y/W/H is
  // the visible rectangle (screen coordinates), ASrcX/Y is where that
  // rectangle starts inside the decoded picture. Without cropping this is
  // just the object's own position and full size; with cropping (see
  // TObjectPosition.HasCrop) it's clipped to the declared crop rectangle
  procedure GetPlacement(const APicIndex: Integer; out ADrawX, ADrawY, ADrawW, ADrawH, ASrcX, ASrcY: Integer);
  var
    k, pw, ph : Integer;
    obj : TObjectPosition;
    hasObj : Boolean;
  begin
    hasObj := False;
    obj.X := 0; obj.Y := 0; obj.HasCrop := False;
    obj.CropX := 0; obj.CropY := 0; obj.CropWidth := 0; obj.CropHeight := 0;

    for k := 0 to High(ds^.Objects) do
      if ds^.Objects[k].ObjectID = ds^.Pictures[APicIndex].ObjectID then
      begin
        obj := ds^.Objects[k];
        hasObj := True;
        Break;
      end;

    pw := ds^.Pictures[APicIndex].Width;
    ph := ds^.Pictures[APicIndex].Height;

    ASrcX := 0;
    ASrcY := 0;
    ADrawX := obj.X;
    ADrawY := obj.Y;
    ADrawW := pw;
    ADrawH := ph;

    if hasObj and obj.HasCrop then
    begin
      // The crop rect is declared in the same screen coordinate space as
      // the object position; clip it to the object's own bounds first
      // (a malformed/edge-case stream could otherwise send us out of
      // range) and translate it into the decoded picture's local space
      ADrawX := EnsureRange(obj.CropX, obj.X, obj.X + pw);
      ADrawY := EnsureRange(obj.CropY, obj.Y, obj.Y + ph);
      ADrawW := EnsureRange(obj.CropWidth, 0, obj.X + pw - ADrawX);
      ADrawH := EnsureRange(obj.CropHeight, 0, obj.Y + ph - ADrawY);
      ASrcX := ADrawX - obj.X;
      ASrcY := ADrawY - obj.Y;
    end;
  end;

begin
  Result := NIL;
  if not ((FDSList.Count > 0) and InRange(DisplaySetIndex, 0, FDSList.Count-1)) then Exit;

  ds := FDSList[DisplaySetIndex];
  if ds = NIL then Exit;

  idx := Length(ds^.Palettes);
  if idx = 0 then Exit;

  with ds^.Palettes[idx-1] do
  begin
    c := Length(Entries);
    if c = 0 then Exit;

    pal := TFPPalette.Create(c);
    pal.Count := c;
    if pal.Count < 256 then
      pal.Count := 256;

    for i := 0 to pal.Count-1 do
      pal[i] := FPColor(0, 0, 0, 0);

    for i := 0 to c-1 do
      pal[Entries[i].PaletteEntryID] := YCbCrToFPColor(Entries[i].Luminance, Entries[i].ColorDifferenceBlue, Entries[i].ColorDifferenceRed, Entries[i].Transparency);
  end;

  try
    c := Length(ds^.Pictures);
    if c = 0 then Exit;

    // First pass: work out each picture's visible rect and the combined
    // bounding box of the whole composite (this also covers the common
    // single-picture, uncropped case - the box just ends up being that
    // one picture's own rect, same result as before)
    minX := MaxInt; minY := MaxInt; maxX := 0; maxY := 0;
    for i := 0 to c-1 do
    begin
      GetPlacement(i, drawX, drawY, drawW, drawH, srcX, srcY);
      if (drawW <= 0) or (drawH <= 0) then Continue; // fully cropped out

      if drawX < minX then minX := drawX;
      if drawY < minY then minY := drawY;
      if drawX + drawW > maxX then maxX := drawX + drawW;
      if drawY + drawH > maxY then maxY := drawY + drawH;
    end;

    if minX = MaxInt then Exit; // nothing actually visible

    Result := TBGRABitmap.Create(Max(1, maxX-minX), Max(1, maxY-minY), BGRAPixelTransparent);

    // Second pass: decode and draw each picture at its resolved position
    for i := 0 to c-1 do
    begin
      GetPlacement(i, drawX, drawY, drawW, drawH, srcX, srcY);
      if (drawW <= 0) or (drawH <= 0) then Continue;

      buf := ReadPictureBuffer(ds^.Pictures[i]);
      if FullColor then
        picBmp := DecodeImage(buf, pal, ds^.Pictures[i].Width, ds^.Pictures[i].Height)
      else
        picBmp := DecodeImage2Colors(buf, pal, ds^.Pictures[i].Width, ds^.Pictures[i].Height);

      if (srcX = 0) and (srcY = 0) and (drawW = picBmp.Width) and (drawH = picBmp.Height) then
        Result.PutImage(drawX - minX, drawY - minY, picBmp, dmDrawWithTransparency)
      else
      begin
        // Cropped: only the visible sub-rectangle gets drawn
        partBmp := picBmp.GetPart(Rect(srcX, srcY, srcX + drawW, srcY + drawH));
        Result.PutImage(drawX - minX, drawY - minY, partBmp, dmDrawWithTransparency);
        partBmp.Free;
      end;
      picBmp.Free;
    end;

    // Reflect the composite/visible region so consumers positioning the
    // result via ds^.X/Y/Width/Height still line things up correctly
    ds^.X := minX;
    ds^.Y := minY;
    ds^.Width := maxX - minX;
    ds^.Height := maxY - minY;
  finally
    pal.Free;
  end;
end;

// -----------------------------------------------------------------------------

function TBlurayPGSParser.SaveBitmapToFile(const DisplaySetIndex: Integer; const FileName: String; const FullColor: Boolean = True): Boolean;
var
  bmp: TBGRABitmap;
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

procedure WriteSUPDisplaySet(const AStream: TStream; const ACompositionNumber: Integer; const AInCue, AOutCue: Int64; const AImage: TBGRABitmap; const AVideoWidth, AVideoHeight: Integer; const AMargins: TRect; const AAlignment: TAlignment = taCenter; const AVerticalAlignment: TVerticalAlignment = taAlignBottom; const AFrameRate: Byte = frf23976; const AMaxColors: Integer = 256; const ADithering: TDitheringAlgorithm = daFloydSteinberg);
var
  pal: TFPPalette = NIL;
  rlebuf: TBytes;
  rlesize: Integer;
  x: Integer;
  it, ft: Int64;
  Xoffset, Yoffset: Integer;
  Y, Cb, Cr: Byte;
  pgs: TPGS;
  pcs: TPCS;
  wds: TWDSNumberOfWindows;
  wdse: TWDSEntry;
  pds: TPDS;
  pdse: TPDSEntry;
  ods: TODS;
  odse: TODSEntry;
  co: TCO;
begin
  // Set 90kHz times
  it := MsToTimestamp(AInCue);
  ft := MsToTimestamp(AOutCue);

  // Get image buffer/pallete
  rlesize := EncodeImage(AImage, rlebuf, pal, AMaxColors, ADithering);
  try

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
    FrameRate := AFrameRate;
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
        Transparency := Hi(pal.Color[x].Alpha);
        AStream.Write(pdse, SizeOf(pdse));
      end;
    end;
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

  finally
    pal.Free;
    SetLength(rlebuf, 0);
  end;
end;

// -----------------------------------------------------------------------------

end.

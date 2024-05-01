{*
 *  URUWorks Blu-ray PGS Parser Utils
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

unit BlurayPGSParser.Utils;

{$I BlurayPGSParser.inc}

interface

uses
  Classes, SysUtils, FPImage, Graphics, Math, BGRABitmap;

function Read2Bytes(const ASource: array of Byte): Integer;
procedure Set2Bytes(var ADest: array of Byte; const ASource: Integer);
function Read3Bytes(const ASource: array of Byte): Integer;
procedure Set3Bytes(var ADest: array of Byte; const ASource: Integer);
function Read4Bytes(const ASource: array of Byte): Integer;
procedure Set4Bytes(var ADest: array of Byte; const ASource: Integer);

function TimestampToMs(const ATimestamp: Integer): Integer;
function MsToTimestamp(const ATimeMS: Integer): Integer;

procedure FPColorToYCbCr(const AColor: TFPColor; out Y, Cb, Cr: Byte);
function YCbCrToFPColor(Y, Cb, Cr, A: Byte): TFPColor;

function EncodeImage(const AImage: TBGRABitmap; out ABuffer: TBytes; out APalette: TFPPalette): Integer;
function DecodeImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer): TBGRABitmap;

//------------------------------------------------------------------------------

implementation

uses
  BGRABitmapTypes, BGRAColorQuantization;

// -----------------------------------------------------------------------------

function Read2Bytes(const ASource: array of Byte): Integer;
begin
  Result := 0;
  if Length(ASource) < 2 then Exit;
  Result := ASource[1] + (ASource[0] shl 8);
end;

// -----------------------------------------------------------------------------

procedure Set2Bytes(var ADest: array of Byte; const ASource: Integer);
begin
  if Length(ADest) < 2 then Exit;
  ADest[0] := Byte(ASource shr 8);
  ADest[1] := Byte(ASource);
end;

// -----------------------------------------------------------------------------

function Read3Bytes(const ASource: array of Byte): Integer;
begin
  Result := 0;
  if Length(ASource) < 3 then Exit;
  Result := (ASource[2] shl 16) + (ASource[1] shl 8) + ASource[0];
end;

// -----------------------------------------------------------------------------

procedure Set3Bytes(var ADest: array of Byte; const ASource: Integer);
begin
  if Length(ADest) < 3 then Exit;
  ADest[0] := Byte(ASource);
  ADest[1] := Byte(ASource shr 8);
  ADest[2] := Byte(ASource shr 16);
end;

// -----------------------------------------------------------------------------

function Read4Bytes(const ASource: array of Byte): Integer;
begin
  Result := 0;
  if Length(ASource) < 4 then Exit;
  Result := ASource[3] + (ASource[2] shl 8) + (ASource[1] shl 16) + (ASource[0] shl 24);
end;

// -----------------------------------------------------------------------------

procedure Set4Bytes(var ADest: array of Byte; const ASource: Integer);
begin
  if Length(ADest) < 4 then Exit;
  ADest[0] := Byte(ASource shr 24);
  ADest[1] := Byte(ASource shr 16);
  ADest[2] := Byte(ASource shr 8);
  ADest[3] := Byte(ASource);
end;

// -----------------------------------------------------------------------------

{ Timestamps conversion }

// -----------------------------------------------------------------------------

function TimestampToMs(const ATimestamp: Integer): Integer;
begin
  Result := ATimestamp div 90;
end;

// -----------------------------------------------------------------------------

function MsToTimestamp(const ATimeMS: Integer): Integer;
begin
  Result := ATimeMS * 90;
end;

// -----------------------------------------------------------------------------

{ BT.601 color conversion }

// -----------------------------------------------------------------------------

procedure FPColorToYCbCr(const AColor: TFPColor; out Y, Cb, Cr: Byte);
begin
  with AColor do
  begin
    Y  := EnsureRange(Round(0.299 * Red + 0.587 * Green + 0.114 * Blue), 16, 235);
    Cb := EnsureRange(Round(-0.169 * Red - 0.331 * Green + 0.5 * Blue) + 128, 16, 240);
    Cr := EnsureRange(Round(0.5 * Red - 0.419 * Green - 0.081 * Blue) + 128, 16, 240);
  end;
end;

// -----------------------------------------------------------------------------

function YCbCrToRGB(Y, Cb, Cr: Integer): TColor;
var
  R, G, B: Integer;
begin
  Y  := Y + 16;
  Cb := Cb - 128;
  Cr := Cr - 128;

  R := EnsureRange(Round(1.164 * Y + 1.596 * Cr), 0, 255);
  G := EnsureRange(Round(1.164 * Y - 0.392 * Cb - 0.813 * Cr), 0, 255);
  B := EnsureRange(Round(1.164 * Y + 2.017 * Cb), 0, 255);

  Result := RGBToColor(R, G, B);
end;

// -----------------------------------------------------------------------------

function YCbCrToFPColor(Y, Cb, Cr, A: Byte): TFPColor;
begin
  Result := TColorToFPColor(YCbCrToRGB(Y, Cb, Cr));
  Result.Alpha := A * $101;
end;

// -----------------------------------------------------------------------------

{ RLE }

// -----------------------------------------------------------------------------

function EncodeImage(const AImage: TBGRABitmap; out ABuffer: TBytes; out APalette: TFPPalette): Integer;
var
  bmp : TBGRABitmap;
  quant : TBGRAColorQuantizer;
  x, y, i, len : Integer;
  p, r : PBGRAPixel;
  bytes : TBytesStream;
  clr : Integer;
begin
  // Reduce image
  bmp := TBGRABitmap.Create(AImage);
  quant := TBGRAColorQuantizer.Create(bmp, acFullChannelInPalette, 256); // reduce colors
  try
    quant.ApplyDitheringInplace(daNearestNeighbor, bmp);
    bmp.UsePalette := True;
    APalette := TFPPalette.Create(quant.ReducedPalette.Count);
    bmp.Palette.Count := APalette.Count;
    for i := 0 to quant.ReducedPalette.Count-1 do // copy reduced colors to palette
    begin
      bmp.Palette[i] := (quant.ReducedPalette.Color[i].ToFPColor);
      APalette.Color[i] := bmp.Palette[i];
    end;

    // RLE compress image
    bytes := TBytesStream.Create;
    try
      for y := 0 to bmp.Height-1 do
      begin
        p := bmp.Scanline[y];
        x := 0;
        while x < bmp.Width do
        begin
          i := quant.ReducedPalette.IndexOfColor(p[x]);
          if i >= 0 then
            clr := i
          else
            clr := quant.ReducedPalette.FindNearestColorIndex(p[x]);

          r := bmp.Scanline[y];
          len := 1;
          while (x + len < bmp.Width) and (len < $3FFF) do
          begin
            if r[x + len] <> p[x] then Break;
            Inc(len);
          end;

          if (len <= 2) and (clr <> 0) then // One pixel in color C
          begin
            bytes.WriteByte(clr);
            if len = 2 then bytes.WriteByte(clr);
          end
          else
          begin
            // rle id
            bytes.WriteByte(0);

            if (clr = 0) and (len < $40) then // L pixels in color 0 (L between 1 and 63)
              bytes.WriteByte(len)
            else if (clr = 0) then  // L pixels in color 0 (L between 64 and 16383)
            begin
              bytes.WriteByte($40 or (len shr 8));
              bytes.WriteByte(len);
            end
            else if len < $40 then // L pixels in color C (L between 3 and 63)
            begin
              bytes.WriteByte($80 or len);
              bytes.WriteByte(clr);
            end
            else // L pixels in color C (L between 64 and 16383)
            begin
              bytes.WriteByte($C0 or (len shr 8));
              bytes.WriteByte(len);
              bytes.WriteByte(clr);
            end;
          end;
          Inc(x, len);
        end;
        // end rle id
        bytes.WriteByte(0);
        bytes.WriteByte(0);
      end;
    finally
      Result := bytes.Size;
      SetLength(ABuffer, Result);
      Move(bytes.Bytes[0], ABuffer[0], Result);
      bytes.Free;
    end;
  finally
    quant.Free;
    bmp.Free;
  end;
end;

// -----------------------------------------------------------------------------

function DecodeImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer): TBGRABitmap;
var
  bmp: TBGRABitmap;
  x, y, idx, i, len: Integer;
  b: Byte;
  clr: TBGRAPixel;
begin
  bmp := TBGRABitmap.Create(AWidth, AHeight, BGRAPixelTransparent);
  idx := 0;
  y := 0;

  if APalette.Count > 0 then
  begin
    while y < bmp.Height do
    begin
      x := 0;
      while x < bmp.Width do
      begin
        if idx >= Length(ABuffer) then
          Break;

        b := ABuffer[idx] and $FF;
        Inc(idx);

        if b = 0 then // RLE ID
        begin
          if idx >= Length(ABuffer) then
            Break;

          b := ABuffer[idx] and $FF;
          Inc(idx);

          if b = 0 then // Next line
          begin
            Inc(y);
            Break;
          end
          else if (b and $C0) = $40 then // L pixels in color 0 (L between 1 and 63)
          begin
            if idx + 1 < Length(ABuffer) then
            begin
              len := ((b - $40) shl 8) or (ABuffer[idx] and $FF);
              Inc(idx);
              clr.FromFPColor(APalette.Color[0]);
              for i := 1 to len do
              begin
                bmp.Scanline[y][x] := clr;
                Inc(x);
              end;
            end;
          end
          else if (b and $C0) = $80 then // L pixels in color C (L between 64 and 16383)
          begin
            if idx < Length(ABuffer) then
            begin
              len := (b - $80);
              b := ABuffer[idx] and $FF;
              Inc(idx);
              clr.FromFPColor(APalette.Color[b]);
              for i := 1 to len do
              begin
                bmp.Scanline[y][x] := clr;
                Inc(x);
              end;
            end;
          end
          else if (b and $C0) <> 0 then // L pixels in color C (L between 3 and 63)
          begin
            if idx + 1 < Length(ABuffer) then
            begin
              len := ((b - $C0) shl 8) or (ABuffer[idx] and $FF);
              Inc(idx);
              if idx < Length(ABuffer) then
              begin
                b := ABuffer[idx] and $FF;
                Inc(idx);
                clr.FromFPColor(APalette.Color[b]);
                for i := 1 to len do
                begin
                  bmp.Scanline[y][x] := clr;
                  Inc(x);
                end;
              end;
            end;
          end
          else // L pixels in color 0 (L between 64 and 16383)
          begin
            clr.FromFPColor(APalette.Color[0]);
            for i := 1 to b do
            begin
              bmp.Scanline[y][x] := clr;
              Inc(x);
            end;
          end;
        end
        else // One pixel in color C
        begin
          clr.FromFPColor(APalette.Color[b]);
          bmp.Scanline[y][x] := clr;
          Inc(x);
        end;
      end;
    end;
    bmp.InvalidateBitmap;
  end;
  Result := bmp;
end;

//------------------------------------------------------------------------------

end.

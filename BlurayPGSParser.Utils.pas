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
 *  Copyright (C) 2023-2026 URUWorks, uruworks@gmail.com.
 *
 *  INFO: https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/
 *
 *}

unit BlurayPGSParser.Utils;

{$I BlurayPGSParser.inc}

interface

uses
  Classes, SysUtils, FPImage, Graphics, Math, BGRABitmap, BGRABitmapTypes;

function Read2Bytes(const ASource: array of Byte): Integer;
procedure Set2Bytes(var ADest: array of Byte; const ASource: Integer);
function Read3Bytes(const ASource: array of Byte): Integer;
procedure Set3Bytes(var ADest: array of Byte; const ASource: Integer);
function Read4Bytes(const ASource: array of Byte): Int64;
procedure Set4Bytes(var ADest: array of Byte; const ASource: Int64);

function TimestampToMs(const ATimestamp: Int64): Int64;
function MsToTimestamp(const ATimeMS: Int64): Int64;

procedure FPColorToYCbCr(const AColor: TFPColor; out Y, Cb, Cr: Byte);
function YCbCrToFPColor(Y, Cb, Cr, A: Byte): TFPColor;

function EncodeImage(const AImage: TBGRABitmap; out ABuffer: TBytes; out APalette: TFPPalette; const AMaxColors: Integer = 256; const ADithering: TDitheringAlgorithm = daFloydSteinberg): Integer;

function DecodeRLEImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer; const ATwoColorThreshold: Integer = -1): TBGRABitmap;
function DecodeImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer): TBGRABitmap;
function DecodeImage2Colors(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer; const AThreshold: Byte = 162): TBGRABitmap;

//------------------------------------------------------------------------------

implementation

uses
  BGRAColorQuantization;

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

function Read4Bytes(const ASource: array of Byte): Int64;
begin
  Result := 0;
  if Length(ASource) < 4 then Exit;
  Result := (Int64(ASource[0]) shl 24) or (Int64(ASource[1]) shl 16) or
            (Int64(ASource[2]) shl 8) or Int64(ASource[3]);
end;

// -----------------------------------------------------------------------------

procedure Set4Bytes(var ADest: array of Byte; const ASource: Int64);
begin
  if Length(ADest) < 4 then Exit;
  ADest[0] := Byte((ASource shr 24) and $FF);
  ADest[1] := Byte((ASource shr 16) and $FF);
  ADest[2] := Byte((ASource shr 8) and $FF);
  ADest[3] := Byte(ASource and $FF);
end;

// -----------------------------------------------------------------------------

{ Timestamps conversion }

// -----------------------------------------------------------------------------

function TimestampToMs(const ATimestamp: Int64): Int64;
begin
  Result := ATimestamp div 90;
end;

// -----------------------------------------------------------------------------

function MsToTimestamp(const ATimeMS: Int64): Int64;
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

function EncodeImage(const AImage: TBGRABitmap; out ABuffer: TBytes; out APalette: TFPPalette; const AMaxColors: Integer = 256; const ADithering: TDitheringAlgorithm = daFloydSteinberg): Integer;
var
  bmp: TBGRABitmap;
  quant: TBGRAColorQuantizer;
  x, y, i, len: Integer;
  p, r: PBGRAPixel;
  bytes: TBytesStream;
  clr: Integer;
  maxColors: Integer;
begin
  // PGS palettes can hold at most 256 entries
  maxColors := EnsureRange(AMaxColors, 2, 256);

  // Reduce image
  bmp := TBGRABitmap.Create(AImage);
  quant := TBGRAColorQuantizer.Create(bmp, acFullChannelInPalette, maxColors); // reduce colors
  try
    quant.ApplyDitheringInplace(ADithering, bmp);
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

function DecodeRLEImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer; const ATwoColorThreshold: Integer = -1): TBGRABitmap;
var
  bmp: TBGRABitmap;
  x, y, idx, i, len: Integer;
  b: Byte;
  clr, clr0, clr1: TBGRAPixel;
  TwoColorMode: Boolean;

  // Resolves a palette index to the pixel color to paint. In two-color mode,
  // collapses everything to either clr0 (background) or clr1 (foreground)
  // based on luminance/alpha threshold
  function ResolveColor(AIndex: Byte): TBGRAPixel;
  var
    IsDark: Boolean;
  begin
    Result.FromFPColor(APalette.Color[AIndex]);
    if not TwoColorMode then Exit;

    IsDark := (Result.red < ATwoColorThreshold) and
              (Result.green < ATwoColorThreshold) and
              (Result.blue < ATwoColorThreshold);

    if IsDark or (Result.alpha < ATwoColorThreshold) then
      Result := clr0
    else
      Result := clr1;
  end;

begin
  TwoColorMode := ATwoColorThreshold >= 0;
  bmp := TBGRABitmap.Create(AWidth, AHeight, BGRAPixelTransparent);
  idx := 0;
  y := 0;

  if APalette.Count > 0 then
  begin
    if TwoColorMode then
    begin
      clr0.FromFPColor(APalette.Color[0]);
      clr1.FromRGB(255, 255, 255);
    end;

    while y < bmp.Height do
    begin
      x := 0;
      while x < bmp.Width do
      begin
        if idx >= Length(ABuffer) then
          Break;

        b := ABuffer[idx] and $FF;
        Inc(idx);

        if b = 0 then // RLE escape
        begin
          if idx >= Length(ABuffer) then
            Break;

          b := ABuffer[idx] and $FF;
          Inc(idx);

          if b = 0 then // End of line
          begin
            Inc(y);
            Break;
          end
          else if (b and $C0) = $40 then // Color 0, long form (L: 64-16383)
          begin
            if idx + 1 < Length(ABuffer) then
            begin
              len := ((b - $40) shl 8) or (ABuffer[idx] and $FF);
              Inc(idx);
              clr := ResolveColor(0);
              for i := 1 to len do
              begin
                bmp.Scanline[y][x] := clr;
                Inc(x);
              end;
            end;
          end
          else if (b and $C0) = $80 then // Color C, short form (L: 3-63)
          begin
            if idx < Length(ABuffer) then
            begin
              len := (b - $80);
              b := ABuffer[idx] and $FF;
              Inc(idx);
              clr := ResolveColor(b);
              for i := 1 to len do
              begin
                bmp.Scanline[y][x] := clr;
                Inc(x);
              end;
            end;
          end
          else if (b and $C0) <> 0 then // Color C, long form (L: 64-16383)
          begin
            if idx + 1 < Length(ABuffer) then
            begin
              len := ((b - $C0) shl 8) or (ABuffer[idx] and $FF);
              Inc(idx);
              if idx < Length(ABuffer) then
              begin
                b := ABuffer[idx] and $FF;
                Inc(idx);
                clr := ResolveColor(b);
                for i := 1 to len do
                begin
                  bmp.Scanline[y][x] := clr;
                  Inc(x);
                end;
              end;
            end;
          end
          else // Color 0, short form (L: 1-63)
          begin
            clr := ResolveColor(0);
            for i := 1 to b do
            begin
              bmp.Scanline[y][x] := clr;
              Inc(x);
            end;
          end;
        end
        else // One pixel in color C
        begin
          clr := ResolveColor(b);
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

function DecodeImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer): TBGRABitmap;
begin
  Result := DecodeRLEImage(ABuffer, APalette, AWidth, AHeight, -1);
end;

//------------------------------------------------------------------------------

function DecodeImage2Colors(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer; const AThreshold: Byte = 162): TBGRABitmap;
begin
  Result := DecodeRLEImage(ABuffer, APalette, AWidth, AHeight, AThreshold);
end;

//------------------------------------------------------------------------------

end.


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

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FPImage, Graphics, Math, BGRABitmap;

function Read2Bytes(const ASource: array of Byte): Integer;
procedure Set2Bytes(var ADest: array of Byte; const ASource: Integer);
function Read3Bytes(const ASource: array of Byte): Integer;
procedure Set3Bytes(var ADest: array of Byte; const ASource: Integer);
function Read4Bytes(const ASource: array of Byte): Integer;
procedure Set4Bytes(var ADest: array of Byte; const ASource: Integer);

function TimestampToMS(const ATime: Integer): Integer;

function YCbCr2FPColor(Y, Cb, Cr, A: Byte): TFPColor;

function DecodeImage(const ABuffer: TBytes; const APalette: TFPPalette; const AWidth, AHeight: Integer): TBGRABitmap;

//------------------------------------------------------------------------------

implementation

uses
  BGRABitmapTypes;

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

{ Timestamps conversion }

// -----------------------------------------------------------------------------

function TimestampToMS(const ATime: Integer): Integer;
begin
  Result := ATime div 90;
end;

// -----------------------------------------------------------------------------

{ Color conversion }

// -----------------------------------------------------------------------------

function YCbCr2RGB(Y, Cb, Cr: Integer): TColor;
var
  R, G, B: Integer;
begin
  Y := Y + 16;
  Cb := Cb - 128;
  Cr := Cr - 128;

  R := EnsureRange(Round(1.164 * Y + 1.596 * Cr), 0, 255);
  G := EnsureRange(Round(1.164 * Y - 0.392 * Cb - 0.813 * Cr), 0, 255);
  B := EnsureRange(Round(1.164 * Y + 2.017 * Cb), 0, 255);

  Result := RGBToColor(R, G, B);
end;

// -----------------------------------------------------------------------------

function YCbCr2FPColor(Y, Cb, Cr, A: Byte): TFPColor;
begin
  Result := TColorToFPColor(YCbCr2RGB(Y, Cb, Cr));
  Result.Alpha := A;
end;

// -----------------------------------------------------------------------------

{ DecodeImage }

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

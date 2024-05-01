{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit UW_BlurayPGSParser;

{$warn 5023 off : no warning about unused units}
interface

uses
  BlurayPGSParser, BlurayPGSParser.Types, BlurayPGSParser.Utils, 
  LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('UW_BlurayPGSParser', @Register);
end.

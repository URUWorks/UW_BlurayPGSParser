unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  BlurayPGSParser, BGRABitmap;

type

  { TForm1 }

  TForm1 = class(TForm)
    Button1: TButton;
    Edit1: TEdit;
    Image1: TImage;
    Label1: TLabel;
    Label2: TLabel;
    ListBox1: TListBox;
    Panel1: TPanel;
    procedure Button1Click(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure ListBox1Click(Sender: TObject);
  private

  public

  end;

var
  Form1: TForm1;
  bd : TBlurayPGSParser;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.Button1Click(Sender: TObject);
var
  i: Integer;
begin
  bd.Parse(edit1.Text);

  Label1.Caption := 'Count: ' + IntToStr(bd.DisplaySets.Count);
  listbox1.Items.BeginUpdate;
  try
    listbox1.Clear;
    for i := 0 to bd.DisplaySets.Count-1 do
      listbox1.Items.Add(Format('#%d: %dms --> %dms', [i+1, bd.DisplaySets[i]^.InCue, bd.DisplaySets[i]^.OutCue]));
  finally
    listbox1.Items.EndUpdate;
  end;

  if listbox1.Count > 0 then
  begin
    listbox1.ItemIndex := 0;
    ListBox1Click(NIL);
  end;
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  bd.Free;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  edit1.Text := ConcatPaths([ExtractFileDir(ParamStr(0)), 'test.sup']);
  bd := TBlurayPGSParser.Create('');
end;

procedure TForm1.ListBox1Click(Sender: TObject);
var
  bmp: TBGRABitmap;
begin
  if listbox1.ItemIndex < 0 then Exit;

  bmp := bd.GetBitmap(listbox1.ItemIndex);
  if bmp = NIL then
    Exit;

  Label2.Caption := inttostr(bmp.Width) + 'x' + inttostr(bmp.Height);
  image1.Picture.Assign(bmp.Bitmap);
end;

end.


unit Boss.Modules.PackageProcessor;

interface

uses
  System.IniFiles, System.Classes, System.Types;

type
  TBossPackageProcessor = class
  private
    FDataFile: TStringList;

    function GetBplList: TStringDynArray;
    function GetBinList(ARootPath: string): TStringDynArray;

    function GetEnv(AEnv: string): string;
    function GetDataCachePath: string;

    procedure SaveData;

    procedure LoadTools(AProjectPath: string);
    procedure MakeLink(AProjectPath, AEnv: string);
    procedure DoLoadBpls(ABpls: TArray<string>);

    constructor Create;
  public
    procedure LoadBpls;
    procedure UnloadOlds;

    class Procedure OnActiveProjectChanged(AProject: string);
    class function GetInstance: TBossPackageProcessor;
  end;


const
  BPLS = 'BPLS';
  DELIMITER = ';';

implementation

uses
  System.IOUtils, Providers.Consts, Boss.IDE.Installer, Providers.Message, Vcl.Dialogs, ToolsAPI,
  Boss.IDE.OpenToolApi.Tools, Winapi.ShellAPI, Winapi.Windows, Vcl.Menus, Boss.EventWrapper, Vcl.Forms, System.SysUtils;

{ TBossPackageProcessor }

var
  _Instance: TBossPackageProcessor;

procedure ExecuteAndWait(const ACommand: string);
var
  LStartup: TStartupInfo;
  LProcess: TProcessInformation;
  LProgram: String;
begin
  LProgram := Trim(ACommand);
  FillChar(LStartup, SizeOf(LStartup), 0);
  LStartup.cb := SizeOf(TStartupInfo);
  LStartup.wShowWindow := SW_HIDE;

  if CreateProcess(nil, pchar(LProgram), nil, nil, true, CREATE_NO_WINDOW,
    nil, nil, LStartup, LProcess) then
  begin
    while WaitForSingleObject(LProcess.hProcess, 10) > 0 do
    begin
      Application.ProcessMessages;
    end;
    CloseHandle(LProcess.hProcess);
    CloseHandle(LProcess.hThread);
  end
  else
  begin
    RaiseLastOSError;
  end;
end;

function TBossPackageProcessor.GetEnv(AEnv: string): string;
begin
  Result := GetEnvironmentVariable('HOMEDRIVE') + GetEnvironmentVariable('HOMEPATH') + TPath.DirectorySeparatorChar +
    C_BOSS_CACHE_FOLDER + TPath.DirectorySeparatorChar + C_ENV + AEnv;
end;


procedure TBossPackageProcessor.MakeLink(AProjectPath, AEnv: string);
var
  LCommand: PChar;
begin
  try
    if DirectoryExists(GetEnv(AEnv)) then
      TFile.Delete(GetEnv(AEnv));
    LCommand := PChar(Format('cmd /c mklink /D /J "%0:s" "%1:s"',
    [GetEnv(AEnv), AProjectPath + TPath.DirectorySeparatorChar + C_MODULES_FOLDER + '.' + AEnv]));
    ExecuteAndWait(LCommand);
  except
    on E: Exception do
      TProviderMessage.GetInstance.WriteLn('Failed on make link: ' + E.Message);
  end;
end;

constructor TBossPackageProcessor.Create;
begin
  FDataFile := TStringList.Create;

  if FileExists(GetDataCachePath) then
    FDataFile.LoadFromFile(GetDataCachePath);

  UnloadOlds;
end;

function TBossPackageProcessor.GetBinList(ARootPath: string): TStringDynArray;
begin
  if not DirectoryExists(ARootPath + C_BIN_FOLDER) then
    Exit();

  Result := TDirectory.GetFiles(ARootPath + C_BIN_FOLDER, '*.exe')
end;

function TBossPackageProcessor.GetBplList: TStringDynArray;
var
  LOrderFileName: string;
  LOrder: TStringList;
  LIndex: Integer;
begin
  if not DirectoryExists(GetEnv(C_ENV_BPL)) then
    Exit();


  LOrderFileName := GetEnv(C_ENV_BPL) + TPath.DirectorySeparatorChar + C_BPL_ORDER;
  if FileExists(LOrderFileName) then
  begin
    LOrder := TStringList.Create;
    try
      LOrder.LoadFromFile(LOrderFileName);
      for LIndex := 0 to LOrder.Count - 1 do
        LOrder.Strings[LIndex] := GetEnv(C_ENV_BPL) + TPath.DirectorySeparatorChar + LOrder.Strings[LIndex];

      Result := LOrder.ToStringArray;
    finally
      LOrder.Free;
    end;
  end
  else
    Result := TDirectory.GetFiles(GetEnv(C_ENV_BPL), '*.bpl')
end;

function TBossPackageProcessor.GetDataCachePath: string;
begin
  Result := GetEnvironmentVariable('HOMEDRIVE') + GetEnvironmentVariable('HOMEPATH') + TPath.DirectorySeparatorChar +
    C_BOSS_CACHE_FOLDER + TPath.DirectorySeparatorChar + C_DATA_FILE;
end;

class function TBossPackageProcessor.GetInstance: TBossPackageProcessor;
begin
  if not Assigned(_Instance) then
    _Instance := TBossPackageProcessor.Create;
  Result := _Instance;
end;

procedure PackageInfoProc(const Name: string; NameType: TNameType; Flags: Byte; Param: Pointer);
begin

end;

procedure TBossPackageProcessor.LoadBpls;
var
  LBpls: TStringDynArray;
begin
  LBpls := GetBplList;
  DoLoadBpls(LBpls);
end;

procedure TBossPackageProcessor.DoLoadBpls(ABpls: TArray<string>);
var
  LBpl: string;
  LFlag: Integer;
  LHnd: NativeUInt;
  LBplsRedo: TStringDynArray;
  LInstalledNew: Boolean;
begin
  LInstalledNew := False;
  LBplsRedo := [];

  for LBpl in ABpls do
  begin
    try
      LHnd := LoadPackage(LBpl);
      GetPackageInfo(LHnd, nil, LFlag, PackageInfoProc);
      UnloadPackage(LHnd);
    except
      on E: Exception do
      begin
        TProviderMessage.GetInstance.WriteLn('Failed to get info of ' + LBpl);
        TProviderMessage.GetInstance.WriteLn(#10 + E.message);
        LBplsRedo := LBplsRedo + [LBpl];
        Continue;
      end;
    end;

    if not(LFlag and pfRunOnly = pfRunOnly) then
    begin
      if TBossIDEInstaller.InstallBpl(LBpl) then
      begin
        TProviderMessage.GetInstance.WriteLn('Instaled: ' + LBpl);
        FDataFile.Add(LBpl);
        LInstalledNew := True;
      end
      else
        LBplsRedo := LBplsRedo + [LBpl];
    end;
  end;
  
  SaveData;

  if LInstalledNew then
  begin
    DoLoadBpls(LBplsRedo);
  end;
end;

procedure TBossPackageProcessor.LoadTools(AProjectPath: string);
var
  LBins: TStringDynArray;
  LBin, LBinName: string;
  LMenu: TMenuItem;
  LMenuItem: TMenuItem;
begin
  LMenu := NativeServices.MainMenu.Items.Find('Tools');
  LBins := GetBinList(AProjectPath);

  NativeServices.MenuBeginUpdate;
  try
    for LBin in LBins do
    begin
      LBinName := ExtractFileName(LBin);
      LMenuItem := TMenuItem.Create(NativeServices.MainMenu);
      LMenuItem.Caption := Providers.Consts.C_BOSS_TAG + ' ' + LBinName;
      LMenuItem.OnClick := GetOpenEvent(LBin);
      LMenuItem.Name := 'boss_' + LBinName.Replace('.', '_');
      LMenuItem.Hint := LBin;
      LMenu.Add(LMenuItem);
    end;
  finally
    NativeServices.MenuEndUpdate;
  end;
end;

class procedure TBossPackageProcessor.OnActiveProjectChanged(AProject: string);
begin
  TProviderMessage.GetInstance.Clear;
  TProviderMessage.GetInstance.WriteLn('Loading packages from project ' + AProject);

  GetInstance.UnloadOlds;
  GetInstance.MakeLink(ExtractFilePath(AProject), C_ENV_BPL);
  GetInstance.MakeLink(ExtractFilePath(AProject), C_ENV_DCU);
  GetInstance.MakeLink(ExtractFilePath(AProject), C_ENV_DCP);
  GetInstance.LoadBpls;
  GetInstance.LoadTools(ExtractFilePath(AProject) + C_MODULES_FOLDER);
end;

procedure TBossPackageProcessor.SaveData;
begin      
  FDataFile.SaveToFile(GetDataCachePath);
end;

procedure TBossPackageProcessor.UnloadOlds;
var
  LBpl: string;
  LMenu: TMenuItem;
  LMenuItem: TMenuItem;
  LIndex: Integer;
begin
  for LBpl in FDataFile do
  begin
    TBossIDEInstaller.RemoveBpl(LBpl);
    TProviderMessage.GetInstance.WriteLn('Removed: ' + LBpl);
    Application.ProcessMessages;
  end;

  FDataFile.Clear;    
  SaveData;
  
  LMenu := NativeServices.MainMenu.Items.Find('Tools');

  NativeServices.MenuBeginUpdate;
  try
    for LIndex := 0 to LMenu.Count - 1 do
    begin
      LMenuItem := LMenu.Items[LIndex];
      if LMenuItem.Caption.StartsWith(C_BOSS_TAG) then
      begin
        LMenu.Remove(LMenuItem);
        LMenuItem.Free;
      end;
    end;
  finally
    NativeServices.MenuEndUpdate;
  end;
end;

initialization

finalization

_Instance.Free;

end.

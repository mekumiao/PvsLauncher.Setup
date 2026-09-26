; AppLauncher 安装包脚本 (Inno Setup 7.x)
; 由 build.ps1 调用，并通过 /DMyAppVersion=<版本> 注入版本号。
;
; 安装模式：免管理员，默认装到当前用户目录 (%LocalAppData%\Programs\AppLauncher)。
; 前置组件（.NET 10 运行时 / Windows App Runtime 2.5.1 / VC++ 运行库）需用户自行预先安装。

#define MyAppName "AppLauncher"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppPublisher "mekumiao"
#define MyAppExeName "AppLauncher.exe"

[Setup]
AppId={{B9A8F1C2-3D4E-4F5A-8B6C-7D8E9F0A1B2C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
; PrivilegesRequired=lowest 时 {autopf} 自动映射到 {userpf} (%LocalAppData%\Programs)，无需管理员。
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=publish
OutputBaseFilename={#MyAppName}-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=windows11 dynamic
; 向导右上角品牌小图（正方形，384x384，DPI 缩放后仍清晰）。
; dynamic 模式下同时指定暗色版本，保证深色系统下仍显示同一品牌图。
WizardSmallImageFile=assets\icons-384.png
WizardSmallImageFileDynamicDark=assets\icons-384.png
; Setup / 卸载程序主图标，多分辨率（16/24/32/48/64/128/256）。
SetupIconFile=assets\AppLauncher.ico
UninstallDisplayIcon={app}\AppLauncher.ico
SetupLogging=yes

; 卸载时的数据清理选项（选择模式窗体）。
[CustomMessages]
chinesesimplified.UninstallOptionsTitle=卸载选项
chinesesimplified.UninstallOptionsText=请选择要一并删除的数据，未勾选项将保留。%n%n请先退出 AppLauncher 再继续。
chinesesimplified.UninstallRemoveUserData=删除用户配置与缓存（%LOCALAPPDATA%\AppLauncher）
chinesesimplified.UninstallOptionsConfirm=开始卸载
chinesesimplified.UninstallOptionsCancel=取消

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 排除调试符号与运行期状态文件，安装包与安装目录都不包含 *.pdb / launcher.state.yaml。
Source: "publish\app\*"; DestDir: "{app}"; Excludes: "*.pdb,launcher.state.yaml"; Flags: ignoreversion recursesubdirs createallsubdirs
; 应用图标随包安装，供快捷方式与卸载项引用。
Source: "assets\AppLauncher.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\AppLauncher.ico"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\AppLauncher.ico"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

; 卸载时删除整个安装目录（含 Dependencies / Configs 等运行期残留）；用户数据在 [Code] 中按需删除。
[UninstallDelete]
Type: filesandordirs; Name: "{app}"

; 卸载前弹出「选择模式」窗体，由用户勾选是否删除用户数据；静默卸载不询问、保留用户数据。
[Code]
var
  RemoveUserData: Boolean;
  UninstallCancelled: Boolean;

{ 显示卸载选项窗体；用户取消时置 UninstallCancelled 以中止卸载。 }
procedure ShowUninstallOptions;
var
  Form: TSetupForm;
  Info: TNewStaticText;
  UserDataCheck: TNewCheckBox;
  ConfirmButton, CancelButton: TNewButton;
  W: Integer;
begin
  Form := CreateCustomForm(ScaleX(400), ScaleY(170), False, False);
  try
    Form.Caption := ExpandConstant('{cm:UninstallOptionsTitle}');

    Info := TNewStaticText.Create(Form);
    Info.Parent := Form;
    Info.Left := ScaleX(16);
    Info.Top := ScaleY(12);
    Info.Width := Form.ClientWidth - ScaleX(32);
    Info.Height := ScaleY(66);
    Info.AutoSize := False;
    Info.WordWrap := True;
    Info.Caption := ExpandConstant('{cm:UninstallOptionsText}');

    UserDataCheck := TNewCheckBox.Create(Form);
    UserDataCheck.Parent := Form;
    UserDataCheck.Left := ScaleX(16);
    UserDataCheck.Top := Info.Top + Info.Height + ScaleY(8);
    UserDataCheck.Width := Form.ClientWidth - ScaleX(32);
    UserDataCheck.Height := ScaleY(20);
    UserDataCheck.Caption := ExpandConstant('{cm:UninstallRemoveUserData}');
    UserDataCheck.Checked := False;

    ConfirmButton := TNewButton.Create(Form);
    ConfirmButton.Parent := Form;
    ConfirmButton.Caption := ExpandConstant('{cm:UninstallOptionsConfirm}');
    ConfirmButton.ModalResult := mrOk;
    ConfirmButton.Default := True;

    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.Caption := ExpandConstant('{cm:UninstallOptionsCancel}');
    CancelButton.ModalResult := mrCancel;
    CancelButton.Cancel := True;

    W := Form.CalculateButtonWidth([ConfirmButton.Caption, CancelButton.Caption]);
    ConfirmButton.Width := W;
    CancelButton.Width := W;
    ConfirmButton.Height := ScaleY(25);
    CancelButton.Height := ScaleY(25);
    CancelButton.Left := Form.ClientWidth - ScaleX(12) - CancelButton.Width;
    ConfirmButton.Left := CancelButton.Left - ScaleX(8) - ConfirmButton.Width;
    ConfirmButton.Top := Form.ClientHeight - ScaleY(12) - ConfirmButton.Height;
    CancelButton.Top := ConfirmButton.Top;

    Form.ActiveControl := ConfirmButton;

    if Form.ShowModal() = mrOk then
      RemoveUserData := UserDataCheck.Checked
    else
      UninstallCancelled := True;
  finally
    Form.Free();
  end;
end;

function InitializeUninstall: Boolean;
begin
  RemoveUserData := False;
  UninstallCancelled := False;

  { 静默卸载不弹窗，保留用户数据。 }
  if UninstallSilent then
  begin
    Result := True;
    Exit;
  end;

  ShowUninstallOptions;
  Result := not UninstallCancelled;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { 安装目录已由 [UninstallDelete] 整体删除；静默卸载不弹窗、保留用户数据。 }
    if UninstallSilent then
      Exit;

    if RemoveUserData then
      DelTree(ExpandConstant('{localappdata}\AppLauncher'), True, True, True);
  end;
end;

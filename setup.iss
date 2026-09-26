; AppLauncher 安装包脚本 (Inno Setup 6.3+ / 7.x)
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

; 卸载时询问是否清理用户数据（%LOCALAPPDATA%\AppLauncher）。
[CustomMessages]
chinesesimplified.UninstallRemoveUserData=是否删除 AppLauncher 的用户配置与缓存目录？%n%n选择「否」将保留这些数据（如需彻底清除，可手动删除该目录）。%n%n请先退出 AppLauncher 再继续。
english.UninstallRemoveUserData=Delete AppLauncher user settings and cache?%n%nChoose No to keep your data (you can delete the folder manually later).%n%nPlease close AppLauncher first.

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 排除所有调试符号，安装包与安装目录都不包含 *.pdb。
Source: "publish\app\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs
; 应用图标随包安装，供快捷方式与卸载项引用。
Source: "assets\AppLauncher.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\AppLauncher.ico"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\AppLauncher.ico"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

; 卸载收尾阶段询问是否删除用户数据目录；静默卸载不询问、保留数据。
[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if UninstallSilent then
      Exit;
    if MsgBox(ExpandConstant('{cm:UninstallRemoveUserData}'),
              mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(ExpandConstant('{localappdata}\AppLauncher'), True, True, True);
  end;
end;

; PvsLauncher 安装包脚本 (Inno Setup 7.x)
; 由 build.ps1 调用，并通过 /DMyAppVersion=<版本> 注入版本号。
;
; 安装模式：免管理员，默认装到当前用户目录 (%LocalAppData%\Programs\PvsLauncher)。
; 前置组件（.NET 10 运行时 / Windows App Runtime 2.5.1 / VC++ 运行库）需用户自行预先安装。

#define MyAppName "PvsLauncher"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppPublisher "mekumiao"
#define MyAppExeName "PvsLauncher.exe"

[Setup]
AppId={{C730741A-09D7-48B9-83EF-BF7D2B4118E8}
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
SetupIconFile=assets\app.ico
UninstallDisplayIcon={app}\app.ico
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 排除调试符号与运行期状态文件，安装包与安装目录都不包含 *.pdb / launcher.state.yaml。
Source: "publish\app\*"; DestDir: "{app}"; Excludes: "*.pdb,launcher.state.yaml"; Flags: ignoreversion recursesubdirs createallsubdirs
; 应用图标随包安装，供快捷方式与卸载项引用。
Source: "assets\app.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app.ico"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\app.ico"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

; 卸载时仅删除整个安装目录（含 Dependencies / Configs 等运行期残留）；
; 用户运行态数据（%LOCALAPPDATA%\PvsLauncher）一律保留。
[UninstallDelete]
Type: filesandordirs; Name: "{app}"

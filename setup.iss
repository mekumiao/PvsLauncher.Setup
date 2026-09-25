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
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 排除所有调试符号，安装包与安装目录都不包含 *.pdb。
Source: "publish\app\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

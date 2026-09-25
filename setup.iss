; AppLauncher 安装包脚本 (Inno Setup 6.3+ / 7.x)
; 由 build.ps1 调用，并通过 /DMyAppVersion=<版本> 注入版本号。
;
; 安装模式：免管理员，默认装到当前用户目录 (%LocalAppData%\Programs\AppLauncher)。
; 前置组件（.NET 10 运行时 / Windows App Runtime 2.5.1 / VC++ 运行库）在安装时联网下载，
; 缺失时才安装；.NET 与 VC++ 需要管理员，会单独触发一次 UAC。

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
WizardStyle=modern
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

[Code]
const
  UrlVcRedist         = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
  UrlDotNetDesktop    = 'https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe';
  UrlDotNetAspNetCore = 'https://aka.ms/dotnet/10.0/aspnetcore-runtime-win-x64.exe';
  UrlWindowsAppRt     = 'https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe';

var
  DownloadPage: TDownloadWizardPage;

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  Result := True;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage('正在准备安装', '正在下载并安装缺失的前置组件，请稍候…', @OnDownloadProgress);
end;

function GetDotNetRuntimes: String;
var
  TempFile: String;
  ResultCode: Integer;
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := '';
  TempFile := ExpandConstant('{tmp}\dotnet-runtimes.txt');
  if Exec(ExpandConstant('{cmd}'), '/c dotnet --list-runtimes > "' + TempFile + '" 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringsFromFile(TempFile, Lines) then
      for I := 0 to GetArrayLength(Lines) - 1 do
        Result := Result + Lines[I] + #13#10;
  end;
end;

function IsWindowsAppRuntimeInstalled: Boolean;
var
  Names: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if RegGetSubkeyNames(HKCU, 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages', Names) then
    for I := 0 to GetArrayLength(Names) - 1 do
      if Pos('Microsoft.WindowsAppRuntime.2.5_', Names[I]) = 1 then
      begin
        Result := True;
        Break;
      end;
end;

function IsVcRedistInstalled: Boolean;
var
  Installed: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and (Installed = 1);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  DotNetRuntimes: String;
  NeedVc, NeedDesktop, NeedAspNetCore, NeedWindowsAppRt: Boolean;
  ResultCode: Integer;
begin
  Result := '';
  NeedsRestart := False;

  DotNetRuntimes := GetDotNetRuntimes;
  NeedVc := not IsVcRedistInstalled;
  NeedDesktop := Pos('Microsoft.WindowsDesktop.App 10.', DotNetRuntimes) = 0;
  NeedAspNetCore := Pos('Microsoft.AspNetCore.App 10.', DotNetRuntimes) = 0;
  NeedWindowsAppRt := not IsWindowsAppRuntimeInstalled;

  if NeedVc or NeedDesktop or NeedAspNetCore or NeedWindowsAppRt then
  begin
    DownloadPage.Clear;
    if NeedVc then DownloadPage.Add(UrlVcRedist, 'vc_redist.x64.exe', '');
    if NeedDesktop then DownloadPage.Add(UrlDotNetDesktop, 'windowsdesktop-runtime-win-x64.exe', '');
    if NeedAspNetCore then DownloadPage.Add(UrlDotNetAspNetCore, 'aspnetcore-runtime-win-x64.exe', '');
    if NeedWindowsAppRt then DownloadPage.Add(UrlWindowsAppRt, 'windowsappruntimeinstall-x64.exe', '');

    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        Result := '下载前置组件失败：' + GetExceptionMessage + #13#10#13#10 +
                  '请确认网络可访问 aka.ms 后重试。';
        Exit;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;

  if NeedVc then
  begin
    if not ShellExec('runas', ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /quiet /norestart', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    begin
      Result := '需要管理员权限安装 Visual C++ 运行库，安装已取消。';
      Exit;
    end;
    if ResultCode = 3010 then
      NeedsRestart := True
    else if ResultCode <> 0 then
    begin
      Result := Format('安装 Visual C++ 运行库失败（错误码 %d）。', [ResultCode]);
      Exit;
    end;
  end;

  if NeedDesktop then
  begin
    if not ShellExec('runas', ExpandConstant('{tmp}\windowsdesktop-runtime-win-x64.exe'), '/install /quiet /norestart', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    begin
      Result := '需要管理员权限安装 .NET 10 Desktop Runtime，安装已取消。';
      Exit;
    end;
    if ResultCode = 3010 then
      NeedsRestart := True
    else if ResultCode <> 0 then
    begin
      Result := Format('安装 .NET 10 Desktop Runtime 失败（错误码 %d）。', [ResultCode]);
      Exit;
    end;
  end;

  if NeedAspNetCore then
  begin
    if not ShellExec('runas', ExpandConstant('{tmp}\aspnetcore-runtime-win-x64.exe'), '/install /quiet /norestart', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    begin
      Result := '需要管理员权限安装 .NET 10 ASP.NET Core Runtime，安装已取消。';
      Exit;
    end;
    if ResultCode = 3010 then
      NeedsRestart := True
    else if ResultCode <> 0 then
    begin
      Result := Format('安装 .NET 10 ASP.NET Core Runtime 失败（错误码 %d）。', [ResultCode]);
      Exit;
    end;
  end;

  if NeedWindowsAppRt then
  begin
    if not Exec(ExpandConstant('{tmp}\windowsappruntimeinstall-x64.exe'), '--quiet', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      Result := '启动 Windows App Runtime 安装器失败。';
      Exit;
    end;
    if ResultCode = 3010 then
      NeedsRestart := True
    else if ResultCode <> 0 then
    begin
      Result := Format('安装 Windows App Runtime 失败（错误码 %d）。', [ResultCode]);
      Exit;
    end;
  end;
end;

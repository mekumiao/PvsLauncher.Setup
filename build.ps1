#requires -Version 7.0
<#
.SYNOPSIS
    构建 PvsLauncher 完整安装包。

.DESCRIPTION
    依次发布 Web、sitecli、前端 dist 与 PvsLauncher，按 launcher.yaml 期望的目录结构组装到
    PvsLauncher.Setup/publish/app，最后调用 Inno Setup 生成安装包到 PvsLauncher.Setup/publish。
    安装包按版本号命名并累积保存：publish/ 下的历史安装包不会在构建时被删除。

.PARAMETER Configuration
    发布配置，默认 Release。

.PARAMETER Version
    指定本次构建版本号，支持三种形式：
    - 不传：直接使用 version.txt 中的版本号（不递增）。
    - +N 或 +x.y.z：在当前 version.txt 版本上递增。+N 只加 patch 段；+x.y.z 逐段相加且不进位。
    - x.y.z：直接使用该版本号。
    版本号会通过 -p:Version 注入 PvsLauncher，并作为安装包版本；
    打包成功后回写 version.txt（即使版本号未变也会刷新文件时间戳）。

.PARAMETER SkipClean
    跳过 publish/app 程序集的清理，做增量构建。历史安装包不受影响。

.PARAMETER SkipVueInstall
    跳过 pnpm install（node_modules 已存在且最新时可选）。

.PARAMETER SkipVue
    跳过前端构建与组装（复用上一次的 dist）。

.PARAMETER SkipApi
    跳过 Web 与 sitecli 的发布（复用上一次的 Dependencies/api）。

.PARAMETER SkipAppLauncher
    跳过 PvsLauncher 的发布（复用上一次的程序集）。

.PARAMETER SkipInstaller
    只构建并组装，不调用 Inno Setup 打包。版本号仍会从 version.txt 读取并注入
    PvsLauncher，但不回写 version.txt。

.EXAMPLE
    pwsh ./build.ps1
.EXAMPLE
    pwsh ./build.ps1 -SkipVue -SkipClean
.EXAMPLE
    pwsh ./build.ps1 -Version +1
.EXAMPLE
    pwsh ./build.ps1 -Version +0.1.0
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$Version,

    [switch]$SkipClean,
    [switch]$SkipVueInstall,
    [switch]$SkipVue,
    [switch]$SkipApi,
    [switch]$SkipAppLauncher,
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
$SetupRoot = $PSScriptRoot
$SourceRoot = Split-Path -Path $SetupRoot -Parent
$PublishRoot = Join-Path $SetupRoot 'publish'
$AppRoot = Join-Path $PublishRoot 'app'
$AppDependencies = Join-Path $AppRoot 'Dependencies'

$PvsRoot = Join-Path $SourceRoot 'ProductVisualStudio'
$VueRoot = Join-Path $SourceRoot 'product-visual-studio-vue'
$LauncherRoot = Join-Path $SourceRoot 'PvsLauncher'
$RuntimeDepsRoot = Join-Path $SourceRoot 'Dependencies'

$WebProject = Join-Path $PvsRoot 'src/ProductVisualStudio.Web/ProductVisualStudio.Web.csproj'
$SiteCliProject = Join-Path $PvsRoot 'src/ProductVisualStudio.SiteCollectors.Client/ProductVisualStudio.SiteCollectors.Client.csproj'
$LauncherProject = Join-Path $LauncherRoot 'src/PvsLauncher/PvsLauncher.csproj'

$IsccScript = Join-Path $SetupRoot 'setup.iss'
$VersionFile = Join-Path $SetupRoot 'version.txt'

# ----------------------------------------------------------------------------
# 通用函数
# ----------------------------------------------------------------------------
function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Section $Name
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
    }
    catch {
        $stopwatch.Stop()
        Write-Host "    FAILED ({0:n1}s): {1}" -f $stopwatch.Elapsed.TotalSeconds, $_.Exception.Message -ForegroundColor Red
        throw
    }

    $stopwatch.Stop()
    Write-Host ("    OK ({0:n1}s)" -f $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $SetupRoot
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        throw "命令失败 (exit $exitCode): $FilePath $($Arguments -join ' ')"
    }
}

function Assert-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Hint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "未找到命令 '$Name'。$Hint"
    }
}

function Assert-Path {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "缺少$Description：$Path"
    }
}

function Reset-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-RuntimeDirectory {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @()
    )

    $source = Join-Path $RuntimeDepsRoot $Name
    $destination = Join-Path $AppDependencies $Name
    Assert-Path -Path $source -Description "运行时依赖目录 Dependencies/$Name"

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    # 排除运行期生成的配置与日志，交由 PvsLauncher 的模板步骤在首次启动时生成。
    $robocopyArgs = @($source, $destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    foreach ($directory in $ExcludeDirectories) {
        $robocopyArgs += @('/XD', (Join-Path $source $directory))
    }
    foreach ($file in $ExcludeFiles) {
        $robocopyArgs += @('/XF', $file)
    }

    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "复制 Dependencies/$Name 失败 (robocopy exit $LASTEXITCODE)"
    }
}

function Read-CurrentVersion {
    if (-not (Test-Path -LiteralPath $VersionFile)) {
        throw "缺少版本文件：$VersionFile"
    }

    $raw = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
    if ($raw -notmatch '^\d+\.\d+\.\d+$') {
        throw "版本文件格式非法（应为 x.y.z）：$VersionFile -> '$raw'"
    }
    return $raw
}

function Get-IncrementedVersion {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$Delta
    )

    if ($Delta -match '^\+(\d+)$') {
        $majorDelta = 0
        $minorDelta = 0
        $patchDelta = [int]$Matches[1]
    }
    elseif ($Delta -match '^\+(\d+)\.(\d+)\.(\d+)$') {
        $majorDelta = [int]$Matches[1]
        $minorDelta = [int]$Matches[2]
        $patchDelta = [int]$Matches[3]
    }
    else {
        throw "版本增量格式非法（应为 +N 或 +x.y.z）：$Delta"
    }

    if (($majorDelta + $minorDelta + $patchDelta) -eq 0) {
        throw "版本增量必须大于 0：$Delta"
    }

    $parts = $Current.Split('.')
    $major = [int]$parts[0] + $majorDelta
    $minor = [int]$parts[1] + $minorDelta
    $patch = [int]$parts[2] + $patchDelta
    return "$major.$minor.$patch"
}

function Save-Version {
    param([Parameter(Mandatory)][string]$Value)

    [System.IO.File]::WriteAllText($VersionFile, "$Value`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-Iscc {
    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $searchRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $searchRoots) {
        $candidate = Get-ChildItem -Path (Join-Path $root 'Inno Setup*\ISCC.exe') -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    throw '未找到 Inno Setup 的 ISCC.exe，请安装 Inno Setup 或使用 -SkipInstaller。'
}

# ----------------------------------------------------------------------------
# 预检
# ----------------------------------------------------------------------------
Write-Section '环境检查'
Assert-Command -Name 'dotnet' -Hint '请安装 .NET 10 SDK。'
Assert-Command -Name 'pnpm' -Hint '请安装 pnpm。'
Assert-Path -Path $WebProject -Description 'Web 项目'
Assert-Path -Path $SiteCliProject -Description 'sitecli 项目'
Assert-Path -Path $LauncherProject -Description 'PvsLauncher 项目'
Assert-Path -Path $VueRoot -Description '前端项目目录'
Assert-Path -Path $IsccScript -Description 'setup.iss'
if (-not $SkipInstaller) {
    $iscc = Resolve-Iscc
    Write-Host "    dotnet / pnpm / ISCC 就绪" -ForegroundColor Green
    Write-Host "    ISCC: $iscc"
}
else {
    Write-Host '    dotnet / pnpm 就绪（已跳过安装包）' -ForegroundColor Green
}

# 版本号：始终解析，供 PvsLauncher 的 -p:Version 与安装包共用；回写 version.txt 只发生在打包成功后。
if (-not $Version) {
    $AppVersion = Read-CurrentVersion
    Write-Host "    构建版本: $AppVersion（使用 version.txt 当前值，不递增）"
}
elseif ($Version -match '^\+') {
    $currentVersion = Read-CurrentVersion
    $AppVersion = Get-IncrementedVersion -Current $currentVersion -Delta $Version
    Write-Host "    构建版本: $AppVersion（version.txt: $currentVersion 递增 $Version）"
}
elseif ($Version -match '^\d+\.\d+\.\d+$') {
    $AppVersion = $Version
    Write-Host "    构建版本: $AppVersion（由 -Version 指定）"
}
else {
    throw "版本号格式非法（应为 x.y.z、+N 或 +x.y.z）：$Version"
}

if ($SkipInstaller) {
    Write-Host '    已跳过安装包：版本仅注入 launcher，不回写 version.txt'
}

# ----------------------------------------------------------------------------
# 清理
# ----------------------------------------------------------------------------
if (-not $SkipClean) {
    Invoke-Step -Name '清理旧的程序集输出' -Action {
        # 只清理 publish/app：旧的程序集必须全量重建，否则残留文件会混进安装包。
        # publish 根目录的安装包按版本号累积，历史产物一律保留，不在此处删除。
        Reset-Directory -Path $AppRoot
    }
}
else {
    New-Item -ItemType Directory -Path $AppRoot -Force | Out-Null
}

# ----------------------------------------------------------------------------
# 1. Web 与 sitecli：合并发布到 Dependencies/api
# ----------------------------------------------------------------------------
$apiOutput = Join-Path $AppDependencies 'api'

if (-not $SkipApi) {
    Invoke-Step -Name '发布 ProductVisualStudio.Web' -Action {
        Invoke-External -FilePath 'dotnet' -Arguments @(
            'publish', $WebProject,
            '-c', $Configuration,
            '-f', 'net10.0',
            '--os', 'win', '-a', 'x64',
            '--self-contained', 'false',
            '-p:PublishSingleFile=false',
            '-p:PublishReadyToRun=false',
            '-o', $apiOutput
        )
    }

    Invoke-Step -Name '发布 ProductVisualStudio.SiteCollectors.Client (sitecli)' -Action {
        Invoke-External -FilePath 'dotnet' -Arguments @(
            'publish', $SiteCliProject,
            '-c', $Configuration,
            '-f', 'net10.0',
            '--os', 'win', '-a', 'x64',
            '--self-contained', 'false',
            '-p:PublishSingleFile=false',
            '-p:PublishReadyToRun=false',
            '-o', $apiOutput
        )
    }
}

# ----------------------------------------------------------------------------
# 2. 前端 dist
# ----------------------------------------------------------------------------
if (-not $SkipVue) {
    if (-not $SkipVueInstall) {
        Invoke-Step -Name '安装前端依赖 (pnpm install)' -Action {
            Invoke-External -FilePath 'pnpm' -Arguments @('install', '--frozen-lockfile') -WorkingDirectory $VueRoot
        }
    }

    Invoke-Step -Name '构建前端 (pnpm build)' -Action {
        Invoke-External -FilePath 'pnpm' -Arguments @('build') -WorkingDirectory $VueRoot
    }

    Invoke-Step -Name '组装前端 dist' -Action {
        $distSource = Join-Path $VueRoot 'dist'
        Assert-Path -Path $distSource -Description '前端构建产物 dist'
        $distTarget = Join-Path $AppDependencies 'dist'
        Reset-Directory -Path $distTarget
        Copy-Item -Path (Join-Path $distSource '*') -Destination $distTarget -Recurse -Force
    }
}

# ----------------------------------------------------------------------------
# 3. PvsLauncher
# ----------------------------------------------------------------------------
if (-not $SkipAppLauncher) {
    Invoke-Step -Name '发布 PvsLauncher' -Action {
        $launcherArgs = @(
            'publish', $LauncherProject,
            '-c', $Configuration,
            '-r', 'win-x64',
            '-o', $AppRoot
        )
        # 让程序集 InformationalVersion（AppInfo.DisplayVersion）与安装包版本一致。
        $launcherArgs += "-p:Version=$AppVersion"
        Invoke-External -FilePath 'dotnet' -Arguments $launcherArgs
    }
}

# ----------------------------------------------------------------------------
# 4. 运行时依赖 (nginx / xray / frp)
# ----------------------------------------------------------------------------
Invoke-Step -Name '组装运行时依赖 (nginx / xray / frp)' -Action {
    New-Item -ItemType Directory -Path $AppDependencies -Force | Out-Null
    Copy-RuntimeDirectory -Name 'nginx' `
        -ExcludeDirectories @('logs', 'temp') `
        -ExcludeFiles @('nginx.conf', 'nginx.conf.bak')
    Copy-RuntimeDirectory -Name 'xray' -ExcludeFiles @('config_client.json')
    Copy-RuntimeDirectory -Name 'frp' -ExcludeFiles @('frpc.toml')

    # nginx 首次启动需要这些运行期目录存在；复制时按约定排除了 logs/ 与 temp/，
    # 这里显式重建，并放入 keep 占位文件，使其随 [Files] 打入安装包并被安装。
    $nginxRoot = Join-Path $AppDependencies 'nginx'
    $nginxRuntimeDirectories = @(
        'logs',
        'temp/client_body_temp',
        'temp/proxy_temp',
        'temp/fastcgi_temp',
        'temp/scgi_temp',
        'temp/uwsgi_temp'
    )
    foreach ($relative in $nginxRuntimeDirectories) {
        $directory = Join-Path $nginxRoot $relative
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $placeholder = Join-Path $directory 'keep'
        if (-not (Test-Path -LiteralPath $placeholder)) {
            New-Item -ItemType File -Path $placeholder -Force | Out-Null
        }
    }
}

# ----------------------------------------------------------------------------
# 5. 清理调试符号与运行状态文件
# ----------------------------------------------------------------------------
Invoke-Step -Name '清理调试符号与运行状态文件' -Action {
    Get-ChildItem -LiteralPath $AppRoot -Recurse -Filter '*.pdb' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force
    # launcher.state.yaml 为运行期生成的状态文件，不应随安装包分发。
    Get-ChildItem -LiteralPath $AppRoot -Recurse -Filter 'launcher.state.yaml' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force
}

# ----------------------------------------------------------------------------
# 6. 打包安装包
# ----------------------------------------------------------------------------
if (-not $SkipInstaller) {
    Invoke-Step -Name '生成安装包 (Inno Setup)' -Action {
        Invoke-External -FilePath $iscc -Arguments @("/DMyAppVersion=$AppVersion", 'setup.iss') -WorkingDirectory $SetupRoot
        Save-Version -Value $AppVersion
        Write-Host "    已写入 version.txt: $AppVersion"
    }

    Write-Section '完成'
    Write-Host "安装包: $PublishRoot\PvsLauncher-Setup-$AppVersion.exe" -ForegroundColor Green
    Write-Host "程序集: $AppRoot"
}
else {
    Write-Section '完成（已跳过安装包）'
    Write-Host "程序集: $AppRoot"
}

#requires -Version 7.0
<#
.SYNOPSIS
    发布 PvsLauncher 新版本：构建安装包、汇总各仓库变更、提交推送并创建/更新 GitHub Release。

.DESCRIPTION
    publish.ps1 以 version.txt 的当前版本（或 -Version 指定的版本）为目标，依次执行：
    1. 采集同级目录下 7 个仓库自上一发布版本（记录在 changelog/state.json）以来的提交；
    2. 调用 build.ps1 构建安装包 publish/PvsLauncher-Setup-<版本>.exe；
    3. 生成 changelog/v<版本>.md 与 CHANGELOG.md，并记录本次基线；
    4. 提交 version.txt 与日志文件，推送到 github 远端；
    5. 在推送后的提交上创建或更新 GitHub Release（先设为草稿），上传安装包与 SHA256 校验文件并校验大小，
       全部成功后再正式发布（draft=false）。

    首次记录以 changelog/state.json 中 1.1.14 的基线为起点，1.1.14 及更早版本不生成日志。
    GitHub 推送只使用 github 远端；origin（Gitee）不会被动到。

.PARAMETER Version
    目标版本，规则与 build.ps1 一致：不传用 version.txt 当前值；+N / +x.y.z 递增；x.y.z 直接指定。

.PARAMETER SkipBuild
    跳过构建，复用 publish/PvsLauncher-Setup-<版本>.exe；版本与 version.txt 不一致时会写回。

.PARAMETER SkipUpload
    完成构建、日志、提交与推送，但不创建/更新 GitHub Release。

.PARAMETER KeepDraft
    只创建/更新草稿 Release 并上传资产，保持草稿状态不发布（便于人工确认后再公开）。

.PARAMETER NoPush
    只在本地生成并提交，不推送、不创建 Release。

.PARAMETER DryRun
    只打印更新日志与执行计划，不写文件、不构建、不推送、不发布。

.PARAMETER Regenerate
    已存在 changelog/v<版本>.md 时强制重新采集并覆盖。

.PARAMETER Force
    跳过安装包体积保护（小于 20 MB 视为构建异常）。

.PARAMETER Repository
    GitHub 仓库，默认 mekumiao/PvsLauncher.Setup。

.PARAMETER GitHubRemote
    已存在的 GitHub 远端名，默认 github。

.PARAMETER Branch
    推送分支，默认取本仓库当前分支。

.PARAMETER SkipClean
    透传给 build.ps1：跳过 publish/app 清理。

.PARAMETER SkipVueInstall
    透传给 build.ps1：跳过 pnpm install。

.PARAMETER SkipVue
    透传给 build.ps1：跳过前端构建与组装。

.PARAMETER SkipApi
    透传给 build.ps1：跳过 Web 与 sitecli 发布。

.PARAMETER SkipAppLauncher
    透传给 build.ps1：跳过 PvsLauncher 发布。

.EXAMPLE
    pwsh ./publish.ps1 -Version +1

.EXAMPLE
    pwsh ./publish.ps1 -SkipBuild

.EXAMPLE
    pwsh ./publish.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Version,

    [switch]$SkipBuild,
    [switch]$SkipUpload,
    [switch]$KeepDraft,
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$Regenerate,
    [switch]$Force,

    [string]$Repository = 'mekumiao/PvsLauncher.Setup',
    [string]$GitHubRemote = 'github',
    [string]$Branch,

    [switch]$SkipClean,
    [switch]$SkipVueInstall,
    [switch]$SkipVue,
    [switch]$SkipApi,
    [switch]$SkipAppLauncher
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
$SetupRoot = $PSScriptRoot
$SourceRoot = Split-Path -Path $SetupRoot -Parent
$PublishRoot = Join-Path $SetupRoot 'publish'
$ChangelogRoot = Join-Path $SetupRoot 'changelog'
$StateFile = Join-Path $ChangelogRoot 'state.json'
$IndexFile = Join-Path $SetupRoot 'CHANGELOG.md'
$VersionFile = Join-Path $SetupRoot 'version.txt'
$BuildScript = Join-Path $SetupRoot 'build.ps1'
$Utf8Encoding = [System.Text.UTF8Encoding]::new($false)

# 展示顺序即日志章节顺序。
$Repositories = @(
    [pscustomobject]@{ Name = 'PvsLauncher'; Path = Join-Path $SourceRoot 'PvsLauncher' }
    [pscustomobject]@{ Name = 'ProductVisualStudio'; Path = Join-Path $SourceRoot 'ProductVisualStudio' }
    [pscustomobject]@{ Name = 'product-visual-studio-vue'; Path = Join-Path $SourceRoot 'product-visual-studio-vue' }
    [pscustomobject]@{ Name = 'PsdRender'; Path = Join-Path $SourceRoot 'PsdRender' }
    [pscustomobject]@{ Name = 'SuCaiFlow'; Path = Join-Path $SourceRoot 'SuCaiFlow' }
    [pscustomobject]@{ Name = 'Dependencies'; Path = Join-Path $SourceRoot 'Dependencies' }
    [pscustomobject]@{ Name = 'PvsLauncher.Setup'; Path = $SetupRoot }
)

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
        Write-Host ("    FAILED ({0:n1}s): {1}" -f $stopwatch.Elapsed.TotalSeconds, $_.Exception.Message) -ForegroundColor Red
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

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $Utf8Encoding)
}

# Git 输出按 UTF-8 解码：系统控制台默认代码页（GB2312）会把中文提交信息读成乱码。
function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = $Utf8Encoding
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }

    $lines = @($output | ForEach-Object { $_.ToString() })
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') 失败（exit $exitCode）：`n$($lines -join "`n")"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
    }
}

# ----------------------------------------------------------------------------
# 版本
# ----------------------------------------------------------------------------
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

    [System.IO.File]::WriteAllText($VersionFile, "$Value`n", $Utf8Encoding)
}

# ----------------------------------------------------------------------------
# 更新日志与基线状态
# ----------------------------------------------------------------------------
function Read-ReleaseState {
    $state = [ordered]@{ schemaVersion = 1; releases = [ordered]@{} }
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $state
    }

    $raw = Get-Content -LiteralPath $StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $state
    }

    $data = $raw | ConvertFrom-Json -AsHashtable
    if (-not $data.Contains('releases')) {
        return $state
    }

    foreach ($versionKey in $data['releases'].Keys) {
        $entry = $data['releases'][$versionKey]
        $state.releases[$versionKey] = [ordered]@{
            releasedAt = $entry['releasedAt']
            tag        = $entry['tag']
            changelog  = $entry['changelog']
            summary    = $entry['summary']
            repos      = $entry['repos']
        }
    }

    return $state
}

function Save-ReleaseState {
    param([Parameter(Mandatory)]$State)

    $releases = [ordered]@{}
    $versionKeys = @($State.releases.Keys) | Sort-Object -Property { [version]$_ }
    foreach ($versionKey in $versionKeys) {
        $entry = $State.releases[$versionKey]

        $repos = [ordered]@{}
        if ($null -ne $entry.repos) {
            foreach ($repo in $Repositories) {
                if ($entry.repos.Contains($repo.Name)) {
                    $repos[$repo.Name] = $entry.repos[$repo.Name]
                }
            }
        }

        $summary = $null
        if ($null -ne $entry.summary) {
            $summary = [ordered]@{}
            foreach ($repo in $Repositories) {
                if ($entry.summary.Contains($repo.Name)) {
                    $summary[$repo.Name] = [int]$entry.summary[$repo.Name]
                }
            }
        }

        $releases[$versionKey] = [ordered]@{
            releasedAt = $entry.releasedAt
            tag        = $entry.tag
            changelog  = $entry.changelog
            summary    = $summary
            repos      = $repos
        }
    }

    $payload = [ordered]@{ schemaVersion = 1; releases = $releases }
    $json = $payload | ConvertTo-Json -Depth 10
    Write-TextFile -Path $StateFile -Content ($json + "`n")
}

function Get-PreviousReleaseVersion {
    param([Parameter(Mandatory)][string]$CurrentVersion)

    $candidates = @(
        @($State.releases.Keys) |
        Where-Object { [version]$_ -lt [version]$CurrentVersion } |
        Sort-Object -Property { [version]$_ } -Descending
    )

    if ($candidates.Count -eq 0) {
        return $null
    }
    return $candidates[0]
}

function Resolve-BaseCommit {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$RepositoryName,
        $PreviousRelease
    )

    $base = $null
    if ($null -ne $PreviousRelease -and $null -ne $PreviousRelease.repos -and
        $PreviousRelease.repos.Contains($RepositoryName)) {
        $base = [string]$PreviousRelease.repos[$RepositoryName]
    }

    if ($base) {
        $check = Invoke-Git -Repository $RepositoryPath -Arguments @('cat-file', '-e', "$base^{commit}") -AllowFailure
        if ($check.ExitCode -eq 0) {
            return $base
        }
        Write-Host "    [警告] $RepositoryName 的基线 $base 不存在，回退到最新标签" -ForegroundColor Yellow
    }

    $tagResult = Invoke-Git -Repository $RepositoryPath -Arguments @('describe', '--tags', '--abbrev=0') -AllowFailure
    if ($tagResult.ExitCode -eq 0 -and $tagResult.Lines.Count -gt 0) {
        $tagBase = $tagResult.Lines[0].Trim()
        Write-Host "    [警告] $RepositoryName 使用最新标签 $tagBase 作为基线" -ForegroundColor Yellow
        return $tagBase
    }

    $rootResult = Invoke-Git -Repository $RepositoryPath -Arguments @('rev-list', '--max-parents=0', 'HEAD')
    $root = $rootResult.Lines[0].Trim()
    Write-Host "    [警告] $RepositoryName 没有可用基线，使用首个提交 $root" -ForegroundColor Yellow
    return $root
}

function Get-RepoChanges {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$BaseCommit,
        [Parameter(Mandatory)][string]$HeadCommit
    )

    if ($BaseCommit -eq $HeadCommit) {
        return @()
    }

    # 字段分隔符用 US(0x1F)，避免提交信息中的空格/中文被拆分。
    $result = Invoke-Git -Repository $RepositoryPath -Arguments @(
        'log', '--no-merges', '--date=short', '--pretty=format:%H%x1f%h%x1f%ad%x1f%s',
        "$BaseCommit..$HeadCommit"
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $result.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line.Split([char]0x1F)
        if ($parts.Count -lt 4) {
            continue
        }
        # 发布提交本身属于元数据，不计入下一次更新日志。
        if ($parts[3] -match '^chore\(release\):') {
            continue
        }
        $changes.Add([pscustomobject]@{
                Hash      = $parts[0]
                ShortHash = $parts[1]
                Date      = $parts[2]
                Subject   = $parts[3]
            })
    }

    return $changes
}

function Format-CommitSubject {
    param([Parameter(Mandatory)][string]$Subject)

    return $Subject.Replace('[', '\[').Replace(']', '\]')
}

function Out-Changelog {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$PreviousVersion,
        [Parameter(Mandatory)]$Changes,
        [Parameter(Mandatory)][string]$Date
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# v$Version")
    $lines.Add('')
    $lines.Add("- 发布日期：$Date")
    if ($PreviousVersion) {
        $lines.Add("- 上一版本：v$PreviousVersion")
    }
    $lines.Add('')

    foreach ($repo in $Repositories) {
        $lines.Add("## $($repo.Name)")
        $entries = @()
        if ($Changes.Contains($repo.Name)) {
            $entries = @($Changes[$repo.Name])
        }

        if ($entries.Count -eq 0) {
            $lines.Add('- 无变动')
        }
        else {
            $limit = 100
            foreach ($entry in ($entries | Select-Object -First $limit)) {
                $subject = Format-CommitSubject -Subject $entry.Subject
                $url = "https://gitee.com/ProductVisualStudio/$($repo.Name)/commit/$($entry.Hash)"
                $lines.Add("- $subject ([$($entry.ShortHash)]($url))")
            }
            if ($entries.Count -gt $limit) {
                $lines.Add("- 其余 $($entries.Count - $limit) 条提交未列出")
            }
        }
        $lines.Add('')
    }

    return (($lines -join "`n").TrimEnd() + "`n")
}

function Out-Index {
    param([Parameter(Mandatory)]$State)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# 更新日志')
    $lines.Add('')
    $lines.Add('> 每个版本的详细内容见 `changelog/` 目录；1.1.14 及更早版本未纳入自动记录。')
    $lines.Add('')
    $lines.Add('| 版本 | 发布日期 | 变更摘要 |')
    $lines.Add('| --- | --- | --- |')

    $versionKeys = @($State.releases.Keys) | Sort-Object -Property { [version]$_ } -Descending
    foreach ($versionKey in $versionKeys) {
        $entry = $State.releases[$versionKey]
        if (-not $entry.changelog) {
            continue
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $entry.summary) {
            foreach ($repo in $Repositories) {
                if ($entry.summary.Contains($repo.Name)) {
                    $count = [int]$entry.summary[$repo.Name]
                    if ($count -gt 0) {
                        $parts.Add("$($repo.Name) $count")
                    }
                }
            }
        }

        $summary = if ($parts.Count -gt 0) { $parts -join ' · ' } else { '无代码变更' }
        $dateText = [string]$entry.releasedAt
        if ($dateText.Length -ge 10) {
            $dateText = $dateText.Substring(0, 10)
        }
        $link = ([string]$entry.changelog).Replace('\', '/')
        $lines.Add("| [v$versionKey]($link) | $dateText | $summary |")
    }

    return (($lines -join "`n").TrimEnd() + "`n")
}

# ----------------------------------------------------------------------------
# GitHub API
# ----------------------------------------------------------------------------
function Invoke-GitHubRest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )

    $headers = @{
        Authorization          = "Bearer $GitHubToken"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'PvsLauncher.Setup-publish'
    }

    $parameters = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $headers
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $parameters['Body'] = ($Body | ConvertTo-Json -Depth 6)
        $parameters['ContentType'] = 'application/json; charset=utf-8'
    }

    $response = Invoke-WebRequest @parameters
    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Content    = [string]$response.Content
    }
}

function Send-ReleaseAsset {
    param(
        [Parameter(Mandatory)][string]$UploadUrl,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    # Token 通过 curl 的 stdin 配置传入，不出现在命令行参数里。
    $curlConfig = (@(
            "header = `"Authorization: Bearer $GitHubToken`""
            'header = "Accept: application/vnd.github+json"'
            'header = "X-GitHub-Api-Version: 2022-11-28"'
            'header = "Content-Type: application/octet-stream"'
            'user-agent = "PvsLauncher.Setup-publish"'
        ) -join "`n") + "`n"

    $previousEncoding = [Console]::OutputEncoding

    # 超过 1 MB 的附件显示 curl 进度条（写 stderr）；stderr 被重定向时保持静默。
    $fileSize = (Get-Item -LiteralPath $Path).Length
    $showProgress = ($fileSize -gt 1MB) -and (-not [Console]::IsErrorRedirected)
    $progressOption = if ($showProgress) { '--progress-bar' } else { '--silent' }

    try {
        [Console]::OutputEncoding = $Utf8Encoding
        $output = $curlConfig | & curl.exe $progressOption --show-error --fail-with-body `
            --connect-timeout 30 --retry 3 --retry-delay 2 `
            --request POST --config - --data-binary "@$Path" $UploadUrl
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }

    $text = @($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        throw "上传资产 $Name 失败（curl exit $exitCode）：$text"
    }

    return ($text | ConvertFrom-Json)
}

# ----------------------------------------------------------------------------
# 预检
# ----------------------------------------------------------------------------
Write-Section '环境检查'
Assert-Command -Name 'git' -Hint '请安装 Git for Windows。'
Assert-Command -Name 'pwsh' -Hint '请安装 PowerShell 7。'
Assert-Command -Name 'curl.exe' -Hint 'Windows 10 1803+ 自带 curl.exe。'
Assert-Path -Path $BuildScript -Description 'build.ps1'

foreach ($repo in $Repositories) {
    Assert-Path -Path $repo.Path -Description "仓库 $($repo.Name)"
    Assert-Path -Path (Join-Path $repo.Path '.git') -Description "仓库 $($repo.Name) 的 .git"
}

$repositoryParts = $Repository -split '/'
if ($repositoryParts.Count -ne 2) {
    throw "Repository 参数格式应为 owner/name：$Repository"
}

$GitHubToken = $env:Github_PvsLauncherSetup_ApiKey
$needPush = (-not $NoPush) -and (-not $DryRun)
$needUpload = (-not $SkipUpload) -and $needPush
if ($needPush -and [string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw '缺少环境变量 Github_PvsLauncherSetup_ApiKey（需要该仓库内容的读写权限）。'
}

if ($needPush) {
    $remoteCheck = Invoke-Git -Repository $SetupRoot -Arguments @('remote', 'get-url', $GitHubRemote) -AllowFailure
    if ($remoteCheck.ExitCode -ne 0) {
        throw "未找到 GitHub 远端 '$GitHubRemote'，请先添加：git remote add $GitHubRemote https://github.com/$Repository.git"
    }
    $remoteUrl = $remoteCheck.Lines[0].Trim()
    if ($remoteUrl -notmatch '^https://') {
        throw "远端 '$GitHubRemote' 不是 HTTPS 地址（$remoteUrl），无法使用 Token 推送。"
    }
}

foreach ($repo in $Repositories) {
    if ($repo.Name -eq 'PvsLauncher.Setup') {
        continue
    }
    $status = Invoke-Git -Repository $repo.Path -Arguments @('status', '--porcelain')
    if ($status.Lines.Count -gt 0) {
        Write-Host "    [提示] $($repo.Name) 工作区有未提交改动，这些改动不会进入更新日志" -ForegroundColor Yellow
    }
}

Write-Host '    git / pwsh / curl 就绪' -ForegroundColor Green

# ----------------------------------------------------------------------------
# 版本与变更
# ----------------------------------------------------------------------------
Write-Section '解析版本'
if (-not $Version) {
    $AppVersion = Read-CurrentVersion
}
elseif ($Version -match '^\+') {
    $AppVersion = Get-IncrementedVersion -Current (Read-CurrentVersion) -Delta $Version
}
elseif ($Version -match '^\d+\.\d+\.\d+$') {
    $AppVersion = $Version
}
else {
    throw "版本号格式非法（应为 x.y.z、+N 或 +x.y.z）：$Version"
}
Write-Host "    发布版本: $AppVersion"

if (-not $Branch) {
    $branchResult = Invoke-Git -Repository $SetupRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $Branch = $branchResult.Lines[0].Trim()
    if ($Branch -eq 'HEAD') {
        throw '当前处于 detached HEAD，无法发布，请先切换到分支。'
    }
}

$ChangelogRelative = "changelog/v$AppVersion.md"
$ChangelogFile = Join-Path $ChangelogRoot "v$AppVersion.md"
$ReuseChangelog = (Test-Path -LiteralPath $ChangelogFile) -and (-not $Regenerate)

$State = Read-ReleaseState
$RepoHeads = [ordered]@{}
$Changes = [ordered]@{}
$Today = (Get-Date).ToString('yyyy-MM-dd')

if ($ReuseChangelog) {
    Write-Host "    复用已有更新日志：$ChangelogRelative"
    $Notes = (Get-Content -LiteralPath $ChangelogFile -Raw).TrimEnd() + "`n"
}
else {
    $PreviousVersion = Get-PreviousReleaseVersion -CurrentVersion $AppVersion
    if (-not $PreviousVersion) {
        throw "找不到 v$AppVersion 之前的基线（changelog/state.json），无法生成更新日志。请确认版本号或补齐基线。"
    }

    Write-Section "采集变更（基线 v$PreviousVersion）"
    $PreviousRelease = $State.releases[$PreviousVersion]
    foreach ($repo in $Repositories) {
        $headCommit = (Invoke-Git -Repository $repo.Path -Arguments @('rev-parse', 'HEAD')).Lines[0].Trim()
        $RepoHeads[$repo.Name] = $headCommit
        $baseCommit = Resolve-BaseCommit -RepositoryPath $repo.Path -RepositoryName $repo.Name -PreviousRelease $PreviousRelease
        $entries = @(Get-RepoChanges -RepositoryPath $repo.Path -BaseCommit $baseCommit -HeadCommit $headCommit)
        $Changes[$repo.Name] = $entries
        Write-Host ("    {0,-28} {1,3} 条" -f $repo.Name, $entries.Count)
    }

    $Notes = Out-Changelog -Version $AppVersion -PreviousVersion $PreviousVersion -Changes $Changes -Date $Today
}

if ($DryRun) {
    Write-Section "更新日志预览（$ChangelogRelative）"
    Write-Host $Notes

    Write-Section '执行计划'
    if ($SkipBuild) {
        Write-Host "    构建: 跳过（复用 publish/PvsLauncher-Setup-$AppVersion.exe）"
    }
    else {
        Write-Host "    构建: pwsh ./build.ps1 -Version $AppVersion"
    }
    Write-Host "    提交: chore(release): v$AppVersion"
    if ($NoPush) {
        Write-Host '    推送: 跳过（-NoPush）'
    }
    else {
        Write-Host "    推送: $GitHubRemote/$Branch"
    }
    if ($SkipUpload -or $NoPush) {
        Write-Host '    Release: 跳过'
    }
    elseif ($KeepDraft) {
        Write-Host "    Release: v$AppVersion（草稿 → 上传资产，保持草稿）"
    }
    else {
        Write-Host "    Release: v$AppVersion（草稿 → 上传资产 → 发布）"
    }
    return
}

# ----------------------------------------------------------------------------
# 构建
# ----------------------------------------------------------------------------
if (-not $SkipBuild) {
    Invoke-Step -Name "构建安装包 v$AppVersion" -Action {
        $buildArguments = @('-NoProfile', '-File', $BuildScript, '-Version', $AppVersion)
        if ($SkipClean) { $buildArguments += '-SkipClean' }
        if ($SkipVueInstall) { $buildArguments += '-SkipVueInstall' }
        if ($SkipVue) { $buildArguments += '-SkipVue' }
        if ($SkipApi) { $buildArguments += '-SkipApi' }
        if ($SkipAppLauncher) { $buildArguments += '-SkipAppLauncher' }
        Invoke-External -FilePath 'pwsh' -Arguments $buildArguments -WorkingDirectory $SetupRoot
    }
}

$versionOnDisk = Read-CurrentVersion
if ($versionOnDisk -ne $AppVersion) {
    if (-not $SkipBuild) {
        throw "构建后 version.txt 为 $versionOnDisk，与目标版本 $AppVersion 不一致。"
    }
    Save-Version -Value $AppVersion
    Write-Host "    已写入 version.txt: $AppVersion"
}

$InstallerPath = Join-Path $PublishRoot "PvsLauncher-Setup-$AppVersion.exe"
Assert-Path -Path $InstallerPath -Description "安装包（请先执行不带 -SkipBuild 的发布）"
$installerSize = (Get-Item -LiteralPath $InstallerPath).Length
Write-Host ("    安装包: {0} ({1:n1} MB)" -f $InstallerPath, ($installerSize / 1MB))
if ($installerSize -lt 20MB -and -not $Force) {
    throw ("安装包体积异常（{0:n2} MB，正常约 150 MB），确认无误后可加 -Force 继续。" -f ($installerSize / 1MB))
}

$Sha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ShaFile = "$InstallerPath.sha256"
Write-TextFile -Path $ShaFile -Content ($Sha256 + '  ' + (Split-Path -Leaf $InstallerPath) + "`n")

# ----------------------------------------------------------------------------
# 写入日志、基线与索引
# ----------------------------------------------------------------------------
Invoke-Step -Name '生成更新日志与基线' -Action {
    if (-not $ReuseChangelog) {
        Write-TextFile -Path $ChangelogFile -Content $Notes
        Write-Host "    已写入 $ChangelogRelative"
    }

    $stateEntryExists = $State.releases.Contains($AppVersion)
    if ((-not $ReuseChangelog) -or (-not $stateEntryExists)) {
        $entryRepos = [ordered]@{}
        $entrySummary = [ordered]@{}
        foreach ($repo in $Repositories) {
            if (-not $RepoHeads.Contains($repo.Name)) {
                $RepoHeads[$repo.Name] = (Invoke-Git -Repository $repo.Path -Arguments @('rev-parse', 'HEAD')).Lines[0].Trim()
            }
            $entryRepos[$repo.Name] = $RepoHeads[$repo.Name]
            $count = 0
            if ($Changes.Contains($repo.Name)) {
                $count = @($Changes[$repo.Name]).Count
            }
            $entrySummary[$repo.Name] = $count
        }

        $State.releases[$AppVersion] = [ordered]@{
            releasedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            tag        = "v$AppVersion"
            changelog  = $ChangelogRelative
            summary    = $entrySummary
            repos      = $entryRepos
        }
        Write-Host "    已记录 v$AppVersion 基线"
    }

    Save-ReleaseState -State $State
    Write-TextFile -Path $IndexFile -Content (Out-Index -State $State)
    Write-Host '    已更新 CHANGELOG.md'
}

# ----------------------------------------------------------------------------
# 提交
# ----------------------------------------------------------------------------
Invoke-Step -Name '提交更新日志' -Action {
    $releasePaths = @('--', 'version.txt', 'CHANGELOG.md', 'changelog')
    Invoke-Git -Repository $SetupRoot -Arguments (@('add') + $releasePaths) | Out-Null
    $staged = Invoke-Git -Repository $SetupRoot -Arguments @('diff', '--cached', '--quiet') -AllowFailure
    if ($staged.ExitCode -eq 0) {
        Write-Host '    没有需要提交的变更'
    }
    elseif ($staged.ExitCode -eq 1) {
        Invoke-Git -Repository $SetupRoot -Arguments (@('commit', '-m', "chore(release): v$AppVersion") + $releasePaths) | Out-Null
        Write-Host "    已提交: chore(release): v$AppVersion"
    }
    else {
        throw "git diff 失败（exit $($staged.ExitCode)）"
    }
}

$commitSha = (Invoke-Git -Repository $SetupRoot -Arguments @('rev-parse', 'HEAD')).Lines[0].Trim()

# ----------------------------------------------------------------------------
# 推送
# ----------------------------------------------------------------------------
if (-not $NoPush) {
    Invoke-Step -Name "推送到 $GitHubRemote/$Branch" -Action {
        $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("x-access-token:$GitHubToken"))
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
        $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $basic"
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            Invoke-Git -Repository $SetupRoot -Arguments @('push', $GitHubRemote, "HEAD:refs/heads/$Branch") | Out-Null
        }
        finally {
            Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        }
        Write-Host "    已推送 $commitSha -> $GitHubRemote/$Branch"

        $commitCheck = Invoke-GitHubRest -Method Get -Uri "https://api.github.com/repos/$Repository/commits/$commitSha"
        if ($commitCheck.StatusCode -ne 200) {
            throw "推送后 GitHub 上找不到提交 $commitSha（HTTP $($commitCheck.StatusCode)）：$($commitCheck.Content)"
        }
    }
}

# ----------------------------------------------------------------------------
# Release
# ----------------------------------------------------------------------------
if ($needUpload) {
    $releaseStepName = if ($KeepDraft) { "上传草稿 Release v$AppVersion" } else { "发布 GitHub Release v$AppVersion" }
    Invoke-Step -Name $releaseStepName -Action {
        $tag = "v$AppVersion"
        $releaseBody = $Notes.TrimEnd() + "`n`n---`n`n" +
        "- 安装包：PvsLauncher-Setup-$AppVersion.exe`n" +
        "- SHA256：$Sha256`n`n" +
        '安装前请先安装 .NET 10 Desktop/ASP.NET Core 运行时、Windows App Runtime 2.5.1、VC++ x64 运行库。' + "`n"

        # 草稿 Release 不会出现在 /releases/tags/{tag}，必须从列表接口里找（有写权限的 token 才能看到草稿）。
        $release = $null
        $listResponse = Invoke-GitHubRest -Method Get -Uri "https://api.github.com/repos/$Repository/releases?per_page=100"
        if ($listResponse.StatusCode -eq 200) {
            $release = @($listResponse.Content | ConvertFrom-Json) |
                Where-Object { $_.tag_name -eq $tag } |
                Select-Object -First 1
        }

        if (-not $release) {
            $tagUri = "https://api.github.com/repos/$Repository/releases/tags/$([uri]::EscapeDataString($tag))"
            $existingRelease = Invoke-GitHubRest -Method Get -Uri $tagUri
            if ($existingRelease.StatusCode -eq 200) {
                $release = $existingRelease.Content | ConvertFrom-Json
            }
            elseif ($existingRelease.StatusCode -ne 404) {
                throw "查询 Release 失败（HTTP $($existingRelease.StatusCode)）：$($existingRelease.Content)"
            }
        }

        $published = $false
        $wasPublished = $false
        try {
            if (-not $release) {
                $payload = [ordered]@{
                    tag_name         = $tag
                    target_commitish = $commitSha
                    name             = $tag
                    body             = $releaseBody
                    draft            = $true
                    prerelease       = $false
                }
                $created = Invoke-GitHubRest -Method Post -Uri "https://api.github.com/repos/$Repository/releases" -Body $payload
                if ($created.StatusCode -ne 201) {
                    throw "创建草稿 Release 失败（HTTP $($created.StatusCode)）：$($created.Content)"
                }
                $release = $created.Content | ConvertFrom-Json
                Write-Host "    已创建草稿 Release $tag（提交 $commitSha）"
            }
            else {
                # 已发布的 Release 先摘成草稿，替换资产期间不对外暴露半成品。
                $wasPublished = -not [bool]$release.draft
                $payload = [ordered]@{
                    name       = $tag
                    body       = $releaseBody
                    draft      = $true
                    prerelease = $false
                }
                if ($release.draft) {
                    # 草稿的 tag 尚未创建，发布时才定位到本次提交。
                    $payload['target_commitish'] = $commitSha
                }
                $updated = Invoke-GitHubRest -Method Patch -Uri "https://api.github.com/repos/$Repository/releases/$($release.id)" -Body $payload
                if ($updated.StatusCode -ne 200) {
                    throw "将 Release 置为草稿失败（HTTP $($updated.StatusCode)）：$($updated.Content)"
                }
                $release = $updated.Content | ConvertFrom-Json
                Write-Host "    已将 Release $tag 置为草稿"
            }

            $assetsResponse = Invoke-GitHubRest -Method Get -Uri "https://api.github.com/repos/$Repository/releases/$($release.id)/assets?per_page=100"
            if ($assetsResponse.StatusCode -ne 200) {
                throw "查询 Release 资产失败（HTTP $($assetsResponse.StatusCode)）：$($assetsResponse.Content)"
            }
            $existingAssets = @($assetsResponse.Content | ConvertFrom-Json)

            $assetFiles = @(
                [pscustomobject]@{ Path = $InstallerPath; Name = (Split-Path -Leaf $InstallerPath) }
                [pscustomobject]@{ Path = $ShaFile; Name = (Split-Path -Leaf $ShaFile) }
            )

            foreach ($assetFile in $assetFiles) {
                $existingAsset = $existingAssets | Where-Object { $_.name -eq $assetFile.Name } | Select-Object -First 1
                if ($existingAsset) {
                    $deleted = Invoke-GitHubRest -Method Delete -Uri "https://api.github.com/repos/$Repository/releases/assets/$($existingAsset.id)"
                    if ($deleted.StatusCode -ne 204) {
                        throw "删除旧资产 $($assetFile.Name) 失败（HTTP $($deleted.StatusCode)）：$($deleted.Content)"
                    }
                    Write-Host "    已删除旧资产 $($assetFile.Name)"
                }

                $uploadUrl = "https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$([uri]::EscapeDataString($assetFile.Name))"
                $uploaded = Send-ReleaseAsset -UploadUrl $uploadUrl -Path $assetFile.Path -Name $assetFile.Name
                $localSize = (Get-Item -LiteralPath $assetFile.Path).Length
                if ([long]$uploaded.size -ne [long]$localSize) {
                    throw "资产 $($assetFile.Name) 大小不一致（远端 $($uploaded.size) / 本地 $localSize）"
                }
                Write-Host ("    已上传 {0} ({1:n1} MB)" -f $assetFile.Name, ($localSize / 1MB))
            }

            if ($KeepDraft) {
                if ($wasPublished) {
                    Write-Host "    Release $tag 原本已发布，现已下线为草稿（-KeepDraft），确认后请手动重新发布" -ForegroundColor Yellow
                }
                else {
                    Write-Host "    Release $tag 保持草稿（-KeepDraft），确认后可在网页上手动发布" -ForegroundColor Yellow
                }
                return
            }

            # 单独一次 PATCH 取消草稿，确保 draft=false 生效后再继续。
            $publishResult = Invoke-GitHubRest -Method Patch -Uri "https://api.github.com/repos/$Repository/releases/$($release.id)" -Body ([ordered]@{ draft = $false })
            if ($publishResult.StatusCode -ne 200) {
                throw "发布 Release 失败（HTTP $($publishResult.StatusCode)）：$($publishResult.Content)"
            }
            $release = $publishResult.Content | ConvertFrom-Json
            if ($release.draft -or -not $release.published_at) {
                throw "发布 Release 后状态异常（draft=$($release.draft), published_at=$($release.published_at)）"
            }
            $published = $true
            Write-Host "    已发布 Release $tag"

            # latest 单独设置，失败只告警：发布本身已经成功。
            $latestResult = Invoke-GitHubRest -Method Patch -Uri "https://api.github.com/repos/$Repository/releases/$($release.id)" -Body ([ordered]@{ make_latest = 'true' })
            if ($latestResult.StatusCode -ne 200) {
                Write-Host "    [提示] 设置 latest 失败（HTTP $($latestResult.StatusCode)）：$($latestResult.Content)" -ForegroundColor Yellow
            }

            Write-Host "    Release: https://github.com/$Repository/releases/tag/$tag" -ForegroundColor Green
        }
        catch {
            if (-not $published -and $release) {
                if ($wasPublished) {
                    Write-Host "    Release $tag 原本已发布，现在停留在草稿状态（未公开）；修复后重跑同一版本即可续传。" -ForegroundColor Yellow
                }
                else {
                    Write-Host "    Release $tag 仍是草稿（未公开），修复后重跑同一版本即可继续。" -ForegroundColor Yellow
                }
            }
            throw
        }
    }
}

Write-Section '完成'
Write-Host "版本: $AppVersion"
Write-Host "安装包: $InstallerPath"
Write-Host "校验文件: $ShaFile"
if ($NoPush) {
    Write-Host '已按 -NoPush 跳过推送与 Release。'
}
elseif ($SkipUpload) {
    Write-Host '已推送到 GitHub，按 -SkipUpload 跳过 Release。'
}
elseif ($KeepDraft) {
    Write-Host "已上传到草稿 Release v$AppVersion（-KeepDraft），确认后请手动发布。" -ForegroundColor Yellow
}
else {
    Write-Host "已发布: https://github.com/$Repository/releases/tag/v$AppVersion" -ForegroundColor Green
}

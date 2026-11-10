# AGENTS.md

## What this repo is

`PvsLauncher.Setup` 是 PvsLauncher 的**构建与打包仓库**，本身不含业务代码。构建入口 `build.ps1` 发布其它仓库、组装运行目录，再用 Inno Setup 打出安装包；发布入口 `publish.ps1` 汇总各仓库变更、生成更新日志、提交推送并维护 GitHub Release。

- `build.ps1` —— 构建 / 组装 / 打包全流程（PowerShell 7+）。
- `publish.ps1` —— 发布流程：生成更新日志 → 构建 → 提交 → 推送 `github` → 创建/更新草稿 Release → 上传资产 → 发布（PowerShell 7+）。
- `setup.iss` —— Inno Setup 安装脚本，`build.ps1` 通过 `/DMyAppVersion=<版本>` 注入版本。
- `version.txt` —— 当前版本号，单行 `x.y.z`，**纳入 git**。
- `changelog/` —— 每版本更新明细 `v<版本>.md` 与基线 `state.json`，**纳入 git**（格式见 `changelog/README.md`）。
- `CHANGELOG.md` —— 由 `state.json` 渲染的索引表，**纳入 git**。
- `assets/` —— 预留资源目录（当前为空）。
- `publish/` —— 所有构建产物，**gitignored，绝不提交**。

脚本默认这些仓库与本仓库同级（用 `$PSScriptRoot/..` 推导，不要改成硬编码绝对路径）：

| 目录                           | 产出                                                         |
| ------------------------------ | ------------------------------------------------------------ |
| `../ProductVisualStudio`       | Web + sitecli（`ProductVisualStudio.SiteCollectors.Client`） |
| `../product-visual-studio-vue` | 前端 `dist`                                                  |
| `../PvsLauncher`               | WinUI 启动器                                                 |
| `../Dependencies`              | nginx / xray / frp 运行时依赖来源                            |
| `../PsdRender`                 | 仅纳入更新日志（不参与构建）                                 |
| `../SuCaiFlow`                 | 仅纳入更新日志（不参与构建）                                 |

`publish.ps1` 还会把本仓库自身（`PvsLauncher.Setup`）纳入更新日志。

## Commands

```pwsh
# 完整构建 + 组装 + 打包（只清理 publish/app，历史安装包保留）
pwsh ./build.ps1

# 复用前端 dist、增量构建后重新打包
pwsh ./build.ps1 -SkipVue -SkipClean

# 在当前版本上递增 patch（成功后写回 version.txt）
pwsh ./build.ps1 -Version +1

# 指定版本（成功后写回 version.txt）
pwsh ./build.ps1 -Version 2.0.0

# 只组装绿色目录，不打包
pwsh ./build.ps1 -SkipInstaller

# 发布新版本：生成日志 → 构建 → 提交 → 推送 github → 创建/更新草稿 Release → 上传 → 发布
pwsh ./publish.ps1 -Version +1

# 只上传到草稿 Release，不发布（人工确认后再手动发布）
pwsh ./publish.ps1 -Version +1 -KeepDraft

# 复用已有安装包，只生成日志并发布
pwsh ./publish.ps1 -SkipBuild

# 只预览更新日志，不写文件、不构建、不推送
pwsh ./publish.ps1 -Version +1 -DryRun

# 本地演练：写日志并提交，不推送、不建 Release
pwsh ./publish.ps1 -Version +1 -SkipBuild -NoPush

# 单独编译安装包（需 publish/app 已存在）
& "C:\Program Files\Inno Setup 7\ISCC.exe" /DMyAppVersion=1.1.1 setup.iss
```

无测试工程、无 CI。验证方式：`build.ps1` 跑通并产出 `publish/PvsLauncher-Setup-x.y.z.exe`；发布流程可先用 `publish.ps1 -DryRun` 核对日志，再真实发布。

## Conventions

- `build.ps1` 必须 **UTF-8 with BOM**（仓库约定；改动后用 `[System.IO.File]::WriteAllText($p,$c,(New-Object System.Text.UTF8Encoding($true)))` 复核）。`publish.ps1` 同样要求 BOM。
- `CHANGELOG.md`、`changelog/*.md`、`changelog/state.json` 用 **UTF-8 无 BOM + LF**，由 `publish.ps1` 写入，不要手工改基线哈希。
- 注释、`Write-Host` 提示、提交信息用中文；提交信息遵循 Conventional Commits。
- 用 4 空格缩进；PowerShell 变量名用 `$PascalCase`（局部循环变量可小写）。
- 路径统一用 `Join-Path` + `$PSScriptRoot` 推导，禁止依赖调用方的工作目录。
- 每个构建步骤用 `Invoke-Step`（计时 + 失败即停）包裹，外部命令走 `Invoke-External`（检查 `$LASTEXITCODE`）。
- **发布只推 `github` 远端**（`origin` 是 Gitee，脚本不动它）。Token 只从 `$env:Github_PvsLauncherSetup_ApiKey` 读取，禁止写入文件、命令行参数或日志。
- 仓库章节顺序固定为：`PvsLauncher`、`ProductVisualStudio`、`product-visual-studio-vue`、`PsdRender`、`SuCaiFlow`、`Dependencies`、`PvsLauncher.Setup`。

## Gotchas

- **版本号**：不传 `-Version` 时直接使用 `version.txt` 当前值（不递增）；传 `+N` 时给 patch 段加 N；传 `+x.y.z` 时逐段相加且不进位；传 `x.y.z` 时直接使用该值。解析出的版本会通过 `-p:Version=$AppVersion` 注入 `PvsLauncher` 的 `dotnet publish`（上游 `AppInfo` 读 `AssemblyInformationalVersion` 显示标题栏版本，`Directory.Build.props` 里的 `<Version>` 仅作 IDE 构建兜底；`AssemblyVersion`/`FileVersion` 不随之变化）。**只有 Inno Setup 编译成功后**才写回 `version.txt`，失败不留缺口；不传参数时也会写回同值以刷新时间戳。`-SkipInstaller` 时仍读 `version.txt` 注入 launcher，但完全不写回。
- **组装布局**必须匹配 `PvsLauncher/src/PvsLauncher/launcher.yaml`：exe 与 `launcher.yaml`、`Configs/` 同级，`Dependencies/` 在其下；nginx 的 `webRoot: ../dist` 相对 `Dependencies/nginx` 指向 `Dependencies/dist`。改动目录结构前先核对 `launcher.yaml`。
- **运行时排除**：复制 `nginx` 时排除 `logs/`、`temp/`、`conf/nginx.conf`、`conf/nginx.conf.bak`；`xray` 排除 `config_client.json`；`frp` 排除 `frpc.toml`。这些都是首次启动由模板生成的运行期文件，不要打包进去。nginx 被排除的 `logs/` 与 `temp/` 下 5 个默认子目录会在复制后显式重建并写入 `keep` 占位文件（`[Files]` 不打包空目录），保证安装后目录存在。
- **ISCC 定位**：先查 PATH，再在 `$env:ProgramFiles` / `${env:ProgramFiles(x86)}` 下找 `Inno Setup*\ISCC.exe`。装的是 Inno Setup 7。
- `setup.iss` 用 `#ifndef MyAppVersion` 兜底，可脱离 `build.ps1` 手动编译，但 `publish/app` 必须已存在，否则 `[Files]` 源匹配失败。
- **安装模式**：`setup.iss` 用 `PrivilegesRequired=lowest`，`{autopf}` 即 `%LocalAppData%\Programs`，**免管理员装用户目录**。不要在管理员模式下写用户目录（Inno 明确不推荐）。
- **前置组件**：`setup.iss` 不含 `[Code]`，安装包不联网安装依赖；.NET 10 Desktop/ASP.NET Core 运行时、Windows App Runtime 2.5.1、VC++ x64 需用户预先装好（通常一次即可）。不要重新引入联网下载逻辑。
- **卸载清理**：整个安装目录 `{app}`（含 `Dependencies`、`Configs` 等全部残留）在 `[UninstallDelete]` 中用 `Type: filesandordirs; Name: "{app}"` **无论是否静默都一律删除**。
- **调试符号与状态文件**：`setup.iss` 的 `[Files]` 用 `Excludes: "*.pdb,launcher.state.yaml"` 排除；`build.ps1` 打包前也会清理 `publish/app` 下 `*.pdb` 与 `launcher.state.yaml`（后者是运行期生成的状态文件，不应随包分发）。
- **上游已知问题**（不在本仓库范围，勿在打包脚本里“修复”）：`PvsLauncher/.../launcher.yaml` 的 nginx 模板路径写作 `./Configs/conf/nginx.conf.template`，但实际文件是 `Configs/nginx.conf.template`（无 `conf/` 子目录），安装后首启可能找不到模板。发现时应指出，而不是默默改 `build.ps1`。
- `publish/` 已被 `.gitignore` 忽略；`.gitignore` 只额外忽略 `*.exe`。
- **历史安装包不清理**：`build.ps1` 的清理步骤只重置 `publish/app`，`publish/` 根目录下的 `PvsLauncher-Setup-*.exe` 按版本累积保留。不要重新加回 `Get-ChildItem -Filter '*.exe' | Remove-Item` 之类的逻辑。同版本重打包时 Inno 会覆盖同名安装包，属预期行为。
- **更新日志基线**：`changelog/state.json` 记录每个版本各仓库的 HEAD。发布 `vX.Y.Z` 时取小于它的最高版本作基线，用 `git log <基线sha>..HEAD` 采集；`1.1.14` 是首次播种（只有哈希、没有日志），因此第一份自动日志是下一个版本。`chore(release): ...` 会被过滤，不计入下一版。基线提交在当前仓库不存在时回退到最新标签，再回退到首个提交，并打印警告。
- **发布顺序与幂等**：构建成功后才写 `version.txt`。构建失败重跑时请给相同的 `-Version`；构建成功但推送或 Release 失败时，直接重跑（不带 `-Version +1`，或显式给同一版本）会复用已有日志、重新推送并 PATCH Release，不会丢提交区间。
- **Release 先草稿后发布**：脚本先创建/把已有 Release 改成草稿（已有正式 Release 会短暂下线），删旧资产、上传，校验大小与 API 返回的 `digest`（`sha256:<hex>`）全部成功后才 `PATCH draft=false` 发布，再单独 `PATCH make_latest=true`（失败只告警）。上传中断会留下草稿，修复后重跑同一版本即可续传。`-KeepDraft` 只建草稿+上传、不发布。**草稿不会出现在 `/releases/tags/{tag}`**，所以查找已有 Release 必须走 `GET /releases?per_page=100`（有写权限的 token 才返回草稿），再退回 tags 接口兜底。上传超过 1 MB 的附件时 curl 用 `--progress-bar` 显示进度条，stderr 被重定向时自动退回 `--silent`。
- **不再上传 `.sha256` 附件**：SHA256 由 GitHub 在接收上传时计算，通过 Release API 的 `digest` 字段提供（客户端 `PvsLauncher.Updating` 直接读它）。脚本仍本地算一次 SHA256 写进 Release 正文并比对 `digest`；大文件上传后 `digest` 可能短暂为空，用 `GET /releases/assets/{id}` 轮询最多 10 次 × 3 秒，仍为空只告警不失败。同版本重发时会显式删除残留的 `<安装包>.sha256` 资产。
- **同版本重发**：已存在 `changelog/v<版本>.md` 时默认复用（`-Regenerate` 才重新采集）；Release 同名资产先删后传；GitHub 上已存在的 `v<版本>` 标签不会被移动，`target_commitish` 只在首次创建或草稿状态时生效。
- **安装包体积保护**：小于 20 MB 直接失败（正常约 150 MB），确认无误可加 `-Force`。`publish/PvsLauncher-Setup-1.1.14.exe` 只有 1.2 MB，是失败产物，不要发布。
- **GitHub 仓库与推送**：`github` 远端已存在，脚本不会创建；空仓库无法建 Release，脚本推送后会先用 API 校验提交存在。Release 只维护当前版本，历史 Release 不动。
- **发布提交范围**：只提交 `version.txt`、`CHANGELOG.md`、`changelog/`，不会带上工作区其它改动（例如未完成的文档修改）。
- 构建产物较大（安装包约 160 MB），验证时避免重复全量打包；可用 `-SkipVue -SkipClean` 加速，发布上传耗时取决于网络。

# AGENTS.md

## What this repo is

`PvsLauncher.Setup` 是 PvsLauncher 的**构建与打包仓库**，本身不含业务代码。唯一的入口脚本 `build.ps1` 会发布其它仓库、组装运行目录，再用 Inno Setup 打出安装包。

- `build.ps1` —— 构建 / 组装 / 打包全流程（PowerShell 7+）。
- `setup.iss` —— Inno Setup 安装脚本，`build.ps1` 通过 `/DMyAppVersion=<版本>` 注入版本。
- `version.txt` —— 当前版本号，单行 `x.y.z`，**纳入 git**。
- `assets/` —— 预留资源目录（当前为空）。
- `publish/` —— 所有构建产物，**gitignored，绝不提交**。

脚本默认这些仓库与本仓库同级（用 `$PSScriptRoot/..` 推导，不要改成硬编码绝对路径）：

| 目录                           | 产出                                                         |
| ------------------------------ | ------------------------------------------------------------ |
| `../ProductVisualStudio`       | Web + sitecli（`ProductVisualStudio.SiteCollectors.Client`） |
| `../product-visual-studio-vue` | 前端 `dist`                                                  |
| `../PvsLauncher`               | WinUI 启动器                                                 |
| `../Dependencies`              | nginx / xray / frp 运行时依赖来源                            |

## Commands

```pwsh
# 完整构建 + 组装 + 打包（默认清理旧输出）
pwsh ./build.ps1

# 复用前端 dist、增量构建后重新打包
pwsh ./build.ps1 -SkipVue -SkipClean

# 在当前版本上递增 patch（成功后写回 version.txt）
pwsh ./build.ps1 -Version +1

# 指定版本（成功后写回 version.txt）
pwsh ./build.ps1 -Version 2.0.0

# 只组装绿色目录，不打包
pwsh ./build.ps1 -SkipInstaller

# 单独编译安装包（需 publish/app 已存在）
& "C:\Program Files\Inno Setup 7\ISCC.exe" /DMyAppVersion=1.1.1 setup.iss
```

无测试工程、无 CI。验证方式：`build.ps1` 跑通并产出 `publish/PvsLauncher-Setup-x.y.z.exe`。

## Conventions

- `build.ps1` 必须 **UTF-8 with BOM**（仓库约定；改动后用 `[System.IO.File]::WriteAllText($p,$c,(New-Object System.Text.UTF8Encoding($true)))` 复核）。
- 注释、`Write-Host` 提示、提交信息用中文；提交信息遵循 Conventional Commits。
- 用 4 空格缩进；PowerShell 变量名用 `$PascalCase`（局部循环变量可小写）。
- 路径统一用 `Join-Path` + `$PSScriptRoot` 推导，禁止依赖调用方的工作目录。
- 每个构建步骤用 `Invoke-Step`（计时 + 失败即停）包裹，外部命令走 `Invoke-External`（检查 `$LASTEXITCODE`）。

## Gotchas

- **版本号**：不传 `-Version` 时直接使用 `version.txt` 当前值（不递增）；传 `+N` 时给 patch 段加 N；传 `+x.y.z` 时逐段相加且不进位；传 `x.y.z` 时直接使用该值。**只有 Inno Setup 编译成功后**才写回 `version.txt`，失败不留缺口；不传参数时也会写回同值以刷新时间戳。`-SkipInstaller` 时完全不读写 `version.txt`。
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
- 构建产物较大（安装包约 160 MB），验证时避免重复全量打包；可用 `-SkipVue -SkipClean` 加速。

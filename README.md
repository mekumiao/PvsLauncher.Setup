# PvsLauncher.Setup

PvsLauncher 一键构建与打包项目：把 **ProductVisualStudio.Web**、**sitecli**、**前端 dist**、**PvsLauncher** 以及 nginx/xray/frp 组装为一个可运行的目录，并调用 [Inno Setup](https://jrsoftware.org/isinfo.php) 生成 Windows 安装包。

## 目录结构

```text
PvsLauncher.Setup/
├─ build.ps1      # 构建、组装、打包脚本
├─ publish.ps1    # 发布脚本：更新日志 → 构建 → 推送 → GitHub Release
├─ setup.iss      # Inno Setup 安装脚本
├─ version.txt    # 当前版本号（由 -Version 控制，见下文）
├─ changelog/     # 每版本更新明细与基线（纳入 git）
├─ CHANGELOG.md   # 更新日志索引
├─ assets/        # 预留的图标等资源目录
└─ publish/       # 构建产物（已 gitignore）
   ├─ app/                          # 待安装的程序集
   │  ├─ PvsLauncher.exe
   │  ├─ launcher.yaml
   │  ├─ Configs/
   │  └─ Dependencies/
   │     ├─ api/                   # Web + sitecli
   │     ├─ dist/                  # 前端
   │     ├─ nginx/
   │     ├─ xray/
   │     └─ frp/
   └─ PvsLauncher-Setup-x.y.z.exe  # 安装包
```

`build.ps1` 假定以下仓库与本项目位于同一个父目录（脚本用 `$PSScriptRoot/..` 自动推导，无需手工改路径）：

| 仓库                        | 用途                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------- |
| `ProductVisualStudio`       | 发布 `ProductVisualStudio.Web` 与 `ProductVisualStudio.SiteCollectors.Client`（sitecli） |
| `product-visual-studio-vue` | 前端，`pnpm build` 产出 `dist`                                                           |
| `PvsLauncher`               | WinUI 启动器主体                                                                         |
| `Dependencies`              | nginx / xray / frp 等运行时依赖来源                                                      |
| `PsdRender`                 | 不参与构建，仅纳入更新日志                                                               |
| `SuCaiFlow`                 | 不参与构建，仅纳入更新日志                                                               |

## 环境要求

- Windows + PowerShell 7+（`#requires -Version 7.0`）
- [.NET 10 SDK](https://dotnet.microsoft.com/)
- [pnpm](https://pnpm.io/)（`pnpm build` 需要 Node.js）
- [Inno Setup 7.x](https://jrsoftware.org/isinfo.php)（仅打包时需要；会从 `Program Files` 自动查找 `ISCC.exe`）

## 安装行为（面向最终用户）

- **免管理员**：安装程序以当前用户权限运行，默认装到 `%LocalAppData%\Programs\PvsLauncher`；开始菜单与卸载信息也写入当前用户。
- **前置组件需自行预先安装**：安装程序不联网下载依赖，运行前需确保已装好以下组件（通常安装一次即可）：
  - [.NET 10 Desktop Runtime](https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe)（PvsLauncher 需要）
  - [.NET 10 ASP.NET Core Runtime](https://aka.ms/dotnet/10.0/aspnetcore-runtime-win-x64.exe)（Web api 需要）
  - [Windows App Runtime 2.5.1 (x64)](https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe)（未打包 WinUI 应用需要）
  - [Visual C++ 2015-2022 x64](https://aka.ms/vs/17/release/vc_redist.x64.exe)（Windows App SDK 要求）
- **不含调试符号与运行状态文件**：安装包排除全部 `*.pdb` 与 `launcher.state.yaml`。
- **卸载时清理**：卸载前弹出「选择模式」窗体，由用户勾选是否删除用户配置与缓存目录 `%LOCALAPPDATA%\PvsLauncher`（应用运行态数据，如 Release 下的 `launcher.state.yaml`），**默认不勾选（保留）**。整个安装目录 `{app}`（含 `Dependencies`、`Configs` 等全部残留）**无论是否静默都由 `[UninstallDelete]` 一律删除**。静默卸载（`/SILENT`、`/VERYSILENT`）不弹窗、保留用户数据。请先退出 PvsLauncher 再卸载。

## 快速开始

```pwsh
# 完整构建 + 组装 + 生成安装包（默认清理旧输出）
pwsh ./build.ps1

# 调试配置
pwsh ./build.ps1 -Configuration Debug
```

## 参数

| 参数               | 类型                 | 默认值    | 说明                                                                                           |
| ------------------ | -------------------- | --------- | ---------------------------------------------------------------------------------------------- |
| `-Configuration`   | `Debug` \| `Release` | `Release` | 传给 `dotnet publish` 的配置。                                                                 |
| `-Version`         | `string`             | 空        | 版本控制：不传用 `version.txt`；传 `+N` / `+x.y.z` 递增；传 `x.y.z` 直接指定。详细规则见下文。 |
| `-SkipClean`       | `switch`             | 关        | 跳过清理 `publish/app` 与旧的 `*.exe`，做增量构建。                                            |
| `-SkipVueInstall`  | `switch`             | 关        | 跳过 `pnpm install`（`node_modules` 已是最新时可选）。                                         |
| `-SkipVue`         | `switch`             | 关        | 跳过前端构建与组装，复用上一次的 `dist`。                                                            |
| `-SkipApi`         | `switch`             | 关        | 跳过 Web 与 sitecli 的发布，复用上一次的 `Dependencies/api`。                                  |
| `-SkipAppLauncher` | `switch`             | 关        | 跳过 PvsLauncher 的发布，复用上一次的程序集。                                                  |
| `-SkipInstaller`   | `switch`             | 关        | 只构建并组装，不调用 Inno Setup 打包；此时不会读写 `version.txt`。                             |

### 常见用法

```pwsh
# 只重新打包安装包，复用上一次的前端 dist，增量构建
pwsh ./build.ps1 -SkipVue -SkipClean

# 前端依赖已安装，跳过 pnpm install
pwsh ./build.ps1 -SkipVueInstall

# 在当前版本上递增 patch 段（成功后写回 version.txt）
pwsh ./build.ps1 -Version +1

# 递增指定段（逐段相加、不进位）
pwsh ./build.ps1 -Version +0.1.0

# 指定版本号发布（成功后写回 version.txt）
pwsh ./build.ps1 -Version 2.0.0

# 只组装可运行的绿色目录，不打安装包
pwsh ./build.ps1 -SkipInstaller

# 复用上次的 api 与 PvsLauncher，只重新构建前端并打包
pwsh ./build.ps1 -SkipApi -SkipAppLauncher -SkipClean

# 复用上次的构建，只重新打安装包
pwsh ./build.ps1 -SkipVue -SkipApi -SkipAppLauncher -SkipClean
```

## 版本管理

版本来源为项目根目录的 `version.txt`（单行纯文本，格式 `x.y.z`）。

- **不传 `-Version`**：直接使用 `version.txt` 中的版本号，**不递增**。
- **传入 `+N`**：在当前版本上只增加 patch 段（`+1` 等价于 `+0.0.1`）。
- **传入 `+x.y.z`**：在当前版本上逐段相加，**不跨段进位**（`1.1.6 + +1.2.3 = 2.3.9`）。
- **传入 `x.y.z`**：直接使用传入值（格式非法会立即报错）。
- **写回时机**：仅当 Inno Setup **编译成功后**才写回 `version.txt`，因此打包失败不会产生版本缺口。
- **`-SkipInstaller`**：不读取也不更新 `version.txt`。
- **时间戳**：不传 `-Version` 时也会写回同值，从而刷新 `version.txt` 的修改时间。

```pwsh
# version.txt = 1.1.6
pwsh ./build.ps1                   # -> PvsLauncher-Setup-1.1.6.exe，version.txt 内容不变、时间戳刷新
pwsh ./build.ps1 -Version +1       # -> PvsLauncher-Setup-1.1.7.exe，version.txt 写回 1.1.7
pwsh ./build.ps1 -Version +0.1.0   # -> PvsLauncher-Setup-1.2.6.exe，version.txt 写回 1.2.6
pwsh ./build.ps1 -Version +1.2.3   # -> PvsLauncher-Setup-2.3.9.exe，version.txt 写回 2.3.9
pwsh ./build.ps1 -Version 2.0.0    # -> PvsLauncher-Setup-2.0.0.exe，version.txt 写回 2.0.0
```

> `version.txt` 需要纳入版本控制；文件缺失或格式非法时脚本会报错退出。

## 构建流程

脚本按以下顺序执行，任一步失败即停止；每步都会打印耗时。

1. **环境检查**：校验 `dotnet` / `pnpm`（打包时含 `ISCC`）以及各项目路径是否存在。
2. **版本决策**：按上节规则确定本次打包版本。
3. **清理**：清空 `publish/app`，删除 `publish/*.exe`（`-SkipClean` 可跳过）。
4. **发布 Web 与 sitecli**：分别以 `dotnet publish` 输出到同一个 `publish/app/Dependencies/api`。
5. **前端**：`pnpm install --frozen-lockfile`（可跳过）→ `pnpm build` → 复制 `dist` 到 `publish/app/Dependencies/dist`。
6. **发布 PvsLauncher**：`dotnet publish -c Release -r win-x64` 输出到 `publish/app`。
7. **组装运行时依赖**：从 `../Dependencies` 复制 `nginx` / `xray` / `frp`，并排除运行期生成的文件（见下）。
8. **清理调试符号与运行状态文件**：递归删除 `publish/app` 下所有 `*.pdb` 与 `launcher.state.yaml`。
9. **打包**：调用 `ISCC.exe /DMyAppVersion=<版本> setup.iss`，成功后写回 `version.txt`。

### 组装规则

最终目录结构与 `PvsLauncher/src/PvsLauncher/launcher.yaml` 的期望一致：`launcher.yaml` 与 exe 同级，`Dependencies/` 位于其下，nginx 的 `webRoot: ../dist` 相对 `Dependencies/nginx` 正好指向 `Dependencies/dist`。

复制运行时依赖时会排除以下**运行期生成物**，交由 PvsLauncher 首次启动时的模板步骤重新生成：

- `nginx/`：排除 `logs/`、`temp/` 目录与 `conf/nginx.conf`、`conf/nginx.conf.bak`；随后重建 `logs/` 及 `temp/` 下的 `client_body_temp`、`proxy_temp`、`fastcgi_temp`、`scgi_temp`、`uwsgi_temp`，并各放入 `keep` 占位文件，确保这些空目录能进入安装包并在安装后存在
- `xray/`：排除 `config_client.json`
- `frp/`：排除 `frpc.toml`

## 输出产物

- 程序集（可直接运行或用于排查）：`publish/app/`
- 安装包：`publish/PvsLauncher-Setup-<版本>.exe`

安装包由 `setup.iss` 定义：产品名 `PvsLauncher`、**免管理员**（装到当前用户目录）、x64、中文界面、开始菜单快捷方式，桌面快捷方式为可选项（安装向导中的任务），安装完成后可选择立即启动。打包时排除所有 `*.pdb` 与 `launcher.state.yaml`；前置组件需用户预先安装（见「安装行为」）。

## 发布版本

`publish.ps1` 把「生成更新日志 → 构建 → 提交 → 推送 → GitHub Release」串成一条命令。它汇总同级目录下 7 个仓库（含本仓库）自上一版本以来的提交，写入 `changelog/`，并把安装包与 SHA256 校验文件上传到 [GitHub Release](https://github.com/mekumiao/PvsLauncher.Setup/releases)。

```pwsh
# 递增 patch 并完整发布
pwsh ./publish.ps1 -Version +1

# 用 version.txt 当前版本重新发布（构建后更新同名 Release）
pwsh ./publish.ps1

# 复用已有安装包，只更新日志与 Release
pwsh ./publish.ps1 -SkipBuild

# 只预览更新日志，不写文件、不构建、不推送
pwsh ./publish.ps1 -Version +1 -DryRun

# 本地生成日志并提交，不推送、不建 Release
pwsh ./publish.ps1 -Version +1 -SkipBuild -NoPush
```

| 参数                                                                     | 说明                                                                 |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| `-Version`                                                               | 与 `build.ps1` 相同的版本规则                                         |
| `-SkipBuild`                                                             | 复用 `publish/PvsLauncher-Setup-<版本>.exe`                           |
| `-SkipUpload`                                                            | 完成推送但不创建/更新 Release                                         |
| `-NoPush`                                                                | 只在本地生成并提交                                                   |
| `-DryRun`                                                                | 只打印更新日志与执行计划                                             |
| `-Regenerate`                                                            | 强制重新采集已存在的版本日志                                         |
| `-Force`                                                                 | 跳过安装包小于 20 MB 的体积保护                                      |
| `-Repository` / `-GitHubRemote` / `-Branch`                              | 默认 `mekumiao/PvsLauncher.Setup` / `github` / 当前分支              |
| `-SkipClean`、`-SkipVueInstall`、`-SkipVue`、`-SkipApi`、`-SkipAppLauncher` | 透传给 `build.ps1`                                                   |

**环境变量**：`Github_PvsLauncherSetup_ApiKey`（该仓库内容的读写权限）。Token 只从环境变量读取，脚本不会写入文件，也不会打印到控制台。

**流程**：

1. 采集 7 个仓库自上一版本基线（`changelog/state.json`）以来的提交，生成 `changelog/v<版本>.md` 与 `CHANGELOG.md` 索引；
2. 调用 `build.ps1` 构建安装包；
3. 提交 `version.txt`、`CHANGELOG.md`、`changelog/`；
4. 推送到 `github` 远端（不动 Gitee 的 `origin`）；
5. 在该提交上创建或更新 `v<版本>` Release，上传 exe 与 `.sha256`。

**注意**：

- 首次基线为 `1.1.14`（只记录提交哈希，不生成日志），第一份自动日志从下一个版本开始。
- 同版本重发会复用已有日志并覆盖同名资产；GitHub 上已存在的标签不会被移动。
- 安装包正常约 150 MB，小于 20 MB 会拒绝发布（`-Force` 可跳过）。
- 构建失败时不会写 `version.txt`；构建成功后若推送或 Release 失败，直接重跑同一版本即可续传。

## 单独使用 Inno Setup

`build.ps1` 会注入版本号；若想手动编译，需要保证 `publish/app` 已存在：

```pwsh
& "C:\Program Files\Inno Setup 7\ISCC.exe" /DMyAppVersion=1.1.1 setup.iss
```

`setup.iss` 中的 `#ifndef MyAppVersion` 提供了兜底默认值，未传 `/D` 时也能编译。

## 常见问题

- **找不到 ISCC.exe**：安装 Inno Setup，或使用 `-SkipInstaller` 只构建程序集。
- **`version.txt` 报错**：确认文件存在且内容形如 `1.1.1`（三段数字）。
- **前端构建失败**：先确认 `pnpm` 可用；必要时去掉 `-SkipVueInstall` 重新执行 `pnpm install`。
- **只想验证组装结果**：使用 `-SkipInstaller`，然后直接运行 `publish/app/PvsLauncher.exe`（运行期无需管理员；nginx/xray 仅监听本机端口，首次可能触发 Windows 防火墙提示）。

# 构建 Aseprite

## 版本和构建目标

默认版本由 [`versions.env`](../tools/aseprite/versions.env) 管理：

```dotenv
ASEPRITE_VERSION=v1.3.18.6
SKIA_VERSION=m124-08a5439a6b
```

首次落地核对日期为 2026-10-25：Aseprite `v1.3.18.6` 是当时[最新正式版](https://github.com/aseprite/aseprite/releases/latest)，其固定 LAF 子模块[要求的 Skia](https://github.com/aseprite/laf/blob/500768cccc6447e3b7816bedbfcb378a5c5222e5/misc/skia-tag.txt) 为 `m124-08a5439a6b`。日常构建不会自动追踪 latest。

| target | GitHub runner | 架构 |
| --- | --- | --- |
| `windows-x64` | `windows-2022` | x64 / MSVC |
| `linux-x64` | `ubuntu-24.04` | x64 / Clang、libstdc++ |
| `macos-arm64` | `macos-15` | Apple Silicon |
| `macos-x64` | `macos-15-intel` | Intel |

使用原生 runner 编译，各平台配置基于[对应版本的上游安装说明](https://github.com/aseprite/aseprite/blob/v1.3.18.6/INSTALL.md)。构建类型固定为 `Release`，Lua scripting 开启，上游测试和 ccache 关闭。设置 `CMAKE_POLICY_VERSION_MINIMUM=3.5`，兼容 runner 上的 CMake 4 与上游部分依赖的旧策略声明。macOS 部署目标分别为 arm64 的 11.0 和 Intel 的 10.14；部署目标不代表已在这些旧系统上验证。

## 在 GitHub Actions 中构建

打开 **Actions → Build Aseprite → Run workflow**，选择含有这些 workflow 的分支。当前仓库使用 `master`，workflow 只接受手动触发。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `target` | `all` | 全部四个平台，或表中的一个 target |
| `aseprite_version` | 空 | 使用固定值；可填写完整的上游 tag，如 `v1.3.18.6` |
| `skia_version` | 空 | 使用固定值；覆盖 Aseprite 时需同步填写兼容的 Skia tag |
| `publish_release` | `true` | 成功后发布；关闭则仅保存 Artifact |

输入通过环境变量传递，再由脚本校验，版本字符串不能作为任意命令或路径使用。脚本会确认源码确为指定 tag，并核对其中 `laf/misc/skia-tag.txt` 与所选 Skia 一致。版本号格式合法但不存在、依赖不匹配或下载失败时，构建会失败，不发布该次产物。

### 打包与验证

共用 [`build.sh`](../tools/aseprite/build.sh) 下载源码及固定子模块、下载对应平台的预编译 Skia，然后使用 CMake / Ninja 编译。每次构建使用 `.work/aseprite/` 下的新目录，避免混入旧构建文件。

ZIP 命名为 `Aseprite-<version>-<target>.zip`，例如 `Aseprite-v1.3.18.6-windows-x64.zip`。Windows / Linux 保留程序、`data/` 和随构建生成的运行库；macOS 保留完整的 `Aseprite.app`，避免打包指向 runner 临时目录的绝对符号链接。程序旁创建 `aseprite.ini`，以便携配置运行。

ZIP 内的 `build-info.txt` 记录 Aseprite tag / commit、Skia tag、目标、工具箱提交、构建时间和运行链接。上游附带的许可与作者文件随 `data/` 保留。

打包后，在新的目录解压，检查可执行权限、`data/gui.xml`、程序版本，并用解压后的程序执行 Lua 批处理，创建并保存一个 PNG。兼容延时绘画插件的版本还会执行真实图像与事件集成测试，覆盖撤销重做、色彩模式、另存为和续录；旧于 1.3.18.6 的覆盖版本跳过插件测试。只有这些检查成功后，ZIP 才会复制到 `dist/` 并上传为 Artifact。

### 下载和发布

- 每个成功的平台保存独立 Artifact，名称为 `aseprite-<target>`，保留 30 天。即使其他平台失败，成功平台的 Artifact 仍可下载。
- 本次选择的全部目标成功，且开启 `publish_release` 后，发布任务才会运行。构建任务只有仓库读取权限，发布任务使用 `GITHUB_TOKEN` 的 `contents: write` 权限。
- 每个上游版本对应一个 Release，例如 `aseprite-v1.3.18.6`，与未来工具自身的版本分开。首次发布先建 draft，上传成功后公开；同版重建只替换本次所选平台的同名附件，保留其他附件。
- 发布任务按 Aseprite 版本使用 concurrency，避免并发修改同版附件。GitHub concurrency 只保留一个运行中和一个等待中的任务，多次快速提交发布可能替换较早的等待任务；其构建 Artifact 仍保留。
- ZIP 内的构建信息为每个平台分别记录。同一 Release 可能包含不同时间、不同工具箱提交构建的附件。
- 附件上传使用覆盖模式，不具备跨附件事务性。发布途中网络失败时查看日志并重跑发布任务；已上传的同名附件可能已更新。

## 本地构建

需要 Bash、Git、curl、CMake、Ninja 和目标平台的原生 C++ 环境。依赖安装方式参考上游安装说明及 workflow 中对应平台的步骤。Windows 使用已初始化 MSVC x64 环境的 Git Bash；Linux 安装 Clang 和 workflow 列出的开发库；macOS 安装 Xcode / SDK 并确认 `xcrun` 可用。

在仓库根目录运行：

```bash
# 只解析默认版本和四平台矩阵，不联网、不编译。
bash tools/aseprite/build.sh resolve

# 在本机原生构建一个目标，替换为与主机相符的 target。
bash tools/aseprite/build.sh build --target windows-x64

# 临时覆盖版本；这里展示与初始固定值相同的兼容组合。
bash tools/aseprite/build.sh build --target linux-x64 \
  --aseprite-version v1.3.18.6 --skia-version m124-08a5439a6b
```

本地构建只输出经过验证的 `dist/*.zip`，不创建 Release。不支持跨平台编译；`all` 只用于解析矩阵或 Actions 输入。

## 更新固定版本

1. 查看 [Aseprite 最新正式版](https://github.com/aseprite/aseprite/releases/latest)，选择明确的版本 tag。
2. 查看该 tag 固定的 `laf` 子模块，再读取其中的 `misc/skia-tag.txt`。Skia 跟随所选 Aseprite 的依赖要求。
3. 在 [Skia Releases](https://github.com/aseprite/skia/releases) 确认所需四个平台的 Release 包都存在。
4. 同步更新 `versions.env` 的版本组合和本文的默认值、核对记录，参考新版本的 `INSTALL.md` 检查编译选项。
5. 先运行轻量检查，再手动构建 `all` 并关闭 `publish_release`，检查四个平台的解压后冒烟检查。需要发布时重新运行并开启发布。

覆盖 tag 只改变本次构建，不回写固定版本。不保证任意历史版本都能使用现有编译参数。

## 检查与排错

日常 push、PR 和手动 **Check toolbox** 运行 actionlint、`bash -n`、ShellCheck，并校验默认矩阵、单平台选择、版本覆盖与无效输入；同时检查延时绘画插件的 Lua 语法、记录生命周期、安装包及四个平台目标的实际 FFmpeg 编码、取消与错误处理。日常检查不下载 Aseprite 或触发完整编译，真实 Aseprite 集成测试随手动完整构建执行。脚本文件通过 `.gitattributes` 固定使用 LF。

| 问题 | 检查方式 |
| --- | --- |
| 版本不存在或下载失败 | 确认上游 tag、Skia 附件名及下载日志 |
| Skia 版本不匹配 | 按错误中提示的 tag 更新配置或本次输入 |
| Windows 找不到 `cl.exe` | 初始化 MSVC x64 环境后启动 Git Bash |
| macOS 资源缺失或不可执行 | 保留完整 `.app`，查看解压后检查的输出 |
| 原生目标不匹配 | 使用与系统、架构对应的 target / runner |
| 无法发布 | 检查全部目标是否成功、发布开关、仓库写权限和发布任务日志 |
| 修改代码后没有自动编译 | 完整编译仅手动触发，push / PR 只进行轻量检查 |

源码、依赖、解压检查文件保留在忽略的 `.work/`，便于本地排错；最终 ZIP 位于忽略的 `dist/`。本地重复构建会积累工作目录，按需清理。脚本失败不会生成新的已验证 ZIP；若 `dist/` 已有上次同名产物，应结合日志和 `build-info.txt` 确认来源。

首次采用或调整构建流程时，需在 GitHub 上验收四个平台的真实构建，并覆盖仅 Artifact、首次 Release、同版单平台替换和部分目标失败等场景。静态检查通过不代表四个平台已经构建通过。

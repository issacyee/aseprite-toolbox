# Aseprite Toolbox

我的个人 Aseprite 工具箱，集中维护从上游源码构建 Aseprite 的流程，以及今后按自己使用习惯编写、修改的扩展和 Lua 脚本。

## 现有能力

- 手动构建 Windows x64、Linux x64、macOS arm64 和 macOS Intel 版本。
- 使用仓库固定的 Aseprite / Skia 版本，支持本次运行覆盖。
- 对最终 ZIP 解压后的程序执行版本和 Lua 批处理检查。
- 保存 Actions Artifact，并按需发布、更新 GitHub Release。

- [延时绘画插件](extensions/timelapse-recorder/README.md)：按作品记录静态绘画过程、自动续录并通过 FFmpeg 导出 MP4。

## 目录导航

| 目录 | 用途 |
| --- | --- |
| [`.github/workflows/`](.github/workflows/) | 构建发布入口和日常轻量检查 |
| [`extensions/`](extensions/) | 通过 Aseprite 扩展机制安装的插件、主题、调色板等 |
| [`scripts/`](scripts/) | 在 Aseprite 内直接运行的独立 Lua 工具 |
| [`tools/`](tools/) | 在 Aseprite 外运行的构建、打包和维护程序 |
| [`docs/`](docs/) | 跨工具的使用和维护说明 |

具体工具的说明、示例和必要资源放在各自目录中。目录名使用英文 `kebab-case`；用户可见内容使用英文，代码注释和文档使用中文，具体边界见 [项目语言规范](AGENTS.md)。新增说明至少记录用途、使用方法、兼容版本；修改外部代码时保留来源和许可说明。外部工具先记录链接，需要实际维护代码时再纳入。

## 构建与下载

在 GitHub 的 **Actions → Build Aseprite → Run workflow** 中选择平台，然后运行。默认构建全部平台并发布 Release；只想验证构建时，关闭 `publish_release`。

- 长期下载：仓库的 **Releases**，tag 为 `aseprite-<上游版本>`。
- 本次运行下载：Actions 运行页面的 **Artifacts**，保留 30 天。
- 固定版本：[`tools/aseprite/versions.env`](tools/aseprite/versions.env)。

完整参数、本地构建、更新版本和排错见 [构建说明](docs/build.md)。日常 push / PR 只运行静态检查，不执行完整编译。

## 维护边界

暂不预设具体插件、统一安装器或共享框架。独立脚本转为可安装扩展时迁移到 `extensions/`，保持一份实现。临时源码、下载依赖和构建文件留在 `.work/`，最终产物留在 `dist/`，两者均不提交。

本仓库自身代码使用 [MIT License](LICENSE)。构建时下载的 Aseprite 与第三方依赖遵循各自的许可，产物保留上游附带的许可文件。

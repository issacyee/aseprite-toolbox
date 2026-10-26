# Aseprite 扩展

存放通过 Aseprite 扩展机制安装的内容，包括脚本插件、主题、调色板等。

- [延时绘画](timelapse-recorder/README.md)：逐操作保存单帧作品的画布，跨次续录并导出 MP4。需要 Aseprite 1.3.18.6+，视频导出另需 FFmpeg。

## 新增约定

每个扩展使用一个英文 `kebab-case` 目录，包含自己的 `package.json`、`README.md`、入口文件和必要资源。文件组织与清单遵循 [Aseprite 官方扩展格式](https://www.aseprite.org/docs/extensions/)；脚本插件同时参考 [Plugin API](https://aseprite.org/api/plugin)。各扩展独立声明版本和兼容性，仓库不设置统一扩展版本。

说明中记录用途、安装和卸载方式、使用步骤、兼容的 Aseprite 版本、已知限制；自改内容记录原项目链接、所基于的版本和改动，并保留原许可。

安装包的根目录直接包含 `package.json`，使用 `.aseprite-extension` 后缀。未来需要自动打包时，将打包程序放在 `tools/`，产物写入忽略的 `dist/`。在首个实际扩展出现前，不添加示例扩展或通用打包框架。

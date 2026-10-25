# 独立 Lua 脚本

存放直接在 Aseprite 中运行的 Lua 工具。目前尚未添加脚本。

## 新增约定

每个工具使用一个英文 `kebab-case` 目录，包含入口 Lua 文件、`README.md` 和必要资源。说明中记录用途、入口文件、安装和运行方式、输入输出、兼容版本及已知限制；自改内容同时记录来源和许可。

在 Aseprite 中通过 **File → Scripts → Open Scripts Folder** 找到用户脚本目录，按具体工具说明复制文件并刷新脚本菜单。脚本 API 和运行方式参考 [官方说明](https://www.aseprite.org/docs/scripting/)。

需要菜单注册、扩展偏好设置或整体安装时，将工具迁移到 `extensions/`，由扩展自己的清单和入口管理。迁移后保留一份实现，不在两个目录重复维护。

在 Aseprite 外运行的 Shell、PowerShell、Python 等维护程序归入 `tools/`。

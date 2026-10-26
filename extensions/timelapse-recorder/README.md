# Timelapse Recorder（延时绘画）

为单帧作品记录作画过程，跨次打开自动续录，通过 FFmpeg 导出无水印 MP4。当前版本为 **0.1.0**，需要 **Aseprite 1.3.18.6 或更新版本**，包含本仓库构建的 `-dev` 版本。同一个 Lua 扩展安装包面向 Windows x64、Linux x64、macOS Intel 和 Apple Silicon。

扩展菜单、提示和错误信息使用英文；下文保留实际菜单和按钮名称，方便对照操作。

## 安装与卸载

在仓库根目录运行，需要 Node.js 20 或更新版本：

```sh
node tools/timelapse/package.mjs
```

生成 `dist/timelapse-recorder-0.1.0.aseprite-extension`。在 Aseprite 中打开 **Edit > Preferences > Extensions > Add Extension**，选择安装包并重启。插件菜单位于 **Sprite > Timelapse**。

卸载时在同一 Extensions 页面移除插件。作品旁的录制文件不会随卸载删除。安装包包含本仓库的 MIT 许可，不附带 FFmpeg，也不修改 Aseprite 本体。

## 录制与导出

1. 打开单帧作品，通过 **Sprite > Timelapse > Recording Panel...** 打开面板，点击 **Enable Recording**。未保存的作品会先打开 Aseprite 的另存为对话框。
2. 插件先保存初始画面，再记录每笔、每次编辑完成后的可见画布，包括撤销、重做和图层显隐变化。连续相同画面会去重；缩放、平移、切换标签和停顿不增加记录帧。
3. 可以随时点击 **Pause** 或 **Resume Recording**。重新打开作品时，插件会恢复该作品此前的录制或暂停状态。
4. 在 **Settings...** 中选择 FFmpeg，或留空使用 PATH 中的 `ffmpeg`。点击 **Export MP4...** 设置输出路径、帧率、整数放大倍率、背景色和结尾停留时间。
5. 导出在后台执行，可以继续绘画，也可以点击 **Cancel Export** 取消。导出使用开始时已保存的记录快照，后续编辑留到下次导出。

Aseprite 可能弹出文件访问或执行外部进程的授权对话框，这是宿主自身的脚本权限。拒绝权限后，插件会暂停并提示；重新授权后再恢复录制。

## FFmpeg 配置

从 [FFmpeg 官方下载入口](https://ffmpeg.org/download.html) 选择系统对应的构建，或通过系统的软件包管理器安装。要求构建包含 **libx264**，可在终端检查：

```sh
ffmpeg -version
ffmpeg -hide_banner -encoders
```

编码器列表应包含 `libx264`。修改 PATH 后需要重启 Aseprite，也可以直接在设置中选择可执行文件。macOS 从桌面启动的应用可能没有终端中的 PATH，建议指定 FFmpeg 的绝对路径。

默认参数为 **24 FPS、1 倍、白色背景、结尾停留 2 秒**。每张过程图对应一帧，因此帧率越低，播放越慢。支持 1–120 FPS、1–16 整数倍、0–60 秒结尾停留，每条输出边长最多 16384 像素。

放大使用最近邻算法，透明区域铺指定背景。历史画布尺寸变化时，较小画面按历史最大宽高居中补齐；为满足 H.264 的偶数边长要求，必要时在右侧或底部额外补 1 像素。

## 记录与迁移

```text
hero.aseprite
hero.timelapse/
  manifest.jsonl
  frame-00000001.png
  frame-00000002.png
```

`manifest.jsonl` 是版本为 1 的逐行 JSON 日志，包含来源、录制状态和帧信息。PNG 保存原始 RGBA 合成画面，不缩放、不铺背景。录制不会向源作品写入额外元数据，也不会改变图层或撤销历史。

- 备份或移动作品时，一起处理 `.timelapse` 文件夹。离线改名时同步改名，例如 `hero.aseprite` / `hero.timelapse` 改为 `enemy.aseprite` / `enemy.timelapse`。
- **Save As** 会复制已有记录，再独立续录，原记录保留。目标记录目录已存在时会暂停，不合并或覆盖历史；解决冲突后再恢复。
- 同一目录中同名、不同格式的作品，例如 `hero.png` 和 `hero.aseprite`，会对应同一记录目录。插件会拒绝混用，请使用不同作品名。每份记录同时只应在一个 Aseprite 进程中录制。
- 每张 PNG 先写入临时名称，再发布并登记日志。重新打开时会扫描完整 PNG，找回日志尾部损坏或追加失败时尚未登记的完整帧；不完整的编号 PNG 会被跳过并暂停，已有编号文件不会覆盖。`manifest.jsonl.bak` 保留修复时的上一份日志。
- 磁盘或权限错误会暂停录制，尚未写入的图像会尽量留在内存，恢复时重试。强制结束或断电仍可能丢失最后待写入的帧，通常为不超过 200 ms 的编辑；队列上限为 8 张图像 / 32 MiB，单张超过此限制的图像立即写盘。
- 记录不会自动删除。需要清理时先暂停、关闭作品，再自行备份或删除对应文件夹。录制或导出期间不要修改其中的 PNG。

导出在目标视频旁创建专属的 `*.timelapse-job-*` 临时目录，只有成功后才发布最终 MP4。失败或取消会清理该任务文件，原始 PNG 始终保留。退出插件会请求取消，下次启动时收尾已终止的任务。系统崩溃留下的任务目录，可在确认编码进程已经结束后自行删除。已有视频在发布失败后无法恢复时，原视频会以 `previous.mp4` 保留在任务目录中，供手动恢复。

## 限制与验证

只能导出启用录制之后的过程，无法还原此前步骤。每笔保留完成后的状态，不包含移动中的光标、笔尖轨迹、选区边框或应用界面。新增动画帧会暂停。0.1 版本不支持动画制作过程、GIF、WebM 或音频。

大画布取样、积压队列写盘和另存为时复制长记录仍使用主线程。队列限制不包含当前取样图和上一张去重图，因此画布尺寸仍会影响峰值内存。导出准备分批进行，视频编码在外部进程中执行。

开发验证命令：

```sh
# 使用 Lua 5.4（需 lua-cjson）或 Aseprite 内置 Lua。
lua5.4 tests/timelapse/run.lua
aseprite -b --script tests/timelapse/run.lua

# 验证真实绘画事件、1000 次编辑、色彩模式、撤销历史和续录。
aseprite -b --script tests/timelapse/aseprite.lua

# Windows 推荐使用此命令等待进程退出并检查结果文件。
# 第二个可执行文件路径可省略，提供后会验证真实的后台编码。
node tools/timelapse/check-aseprite.mjs /path/to/aseprite /path/to/ffmpeg

# 验证实际编码、取消、错误处理、特殊路径和安装包。
node --test tests/timelapse/package.test.mjs tests/timelapse/workers.test.mjs
```

工作进程测试需要 PATH 中的 FFmpeg 和 ffprobe，或在 `FFMPEG`、`FFPROBE` 中设置绝对路径。Windows 还可以通过 `TIMELAPSE_POSIX_SHELL` 指定 Git 的 `sh.exe`，额外验证 POSIX 工作脚本。真实 Aseprite 测试产物写入忽略的 `.work/` 目录。

CI 已为四个平台目标配置工作进程检查；手动构建 Aseprite 时，还会运行真实图像与事件集成测试。无界面检查不能证明其他操作系统上的 GUI 响应表现。

本扩展为独立实现，依据官方 [Plugin API](https://www.aseprite.org/api/plugin/)、[Sprite 事件](https://www.aseprite.org/api/sprite/#spriteevents)和 [Image API](https://www.aseprite.org/api/image/) 接入。

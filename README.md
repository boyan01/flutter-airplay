# Flutter AirPlay

一个 GPLv3 开源的 AirPlay 接收器，用于在同一局域网内接收 iPhone 屏幕镜像。
macOS 和 Android 共用 Flutter 界面、UxPlay 接收协议与 C++ 播放核心；
Windows、Linux 和 iPad 宿主复用同一工程，当前属于待设备验证的实验性实现。
共享核心处理时间戳、缓冲和会话重置，解码与音频输出使用平台适配层。

应用默认启动接收。待命首页显示设备名和投屏指引，收到画面后自动切换到播放页。
提供设备名设置、接收开关、全屏和日志；外观跟随系统，TV 始终使用深色。
界面支持简体中文和英文，跟随系统语言。原生错误原因和运行日志保留宿主原文。
Android 还提供 TV 布局与遥控器方向键操作。macOS 始终在同一个应用窗口中播放。
不支持 DRM 内容，不承诺点对点连接。

当前版本为 **0.1.2+3**，属于本地开发版本。

## 平台支持

| 平台 | 当前支持范围 |
| --- | --- |
| macOS | macOS 12+、Apple Silicon，应用包内置依赖，无需安装 Homebrew 或 GStreamer |
| Android 手机 | Android 8.0（API 26）及以上，当前仅打包 arm64-v8a |
| Android TV | 共用 Android 应用，提供 TV 布局与遥控器方向键操作，当前仅打包 arm64-v8a |
| iPad | iPadOS 15+，前台接收实现；切到后台停止接收，真实 iPhone 播放仍需验证 |
| Windows | Windows 10+ x64 实验性代码，尚未在 Windows 编译/运行；支持路径为 H.264、AAC-LC、ALAC，AAC-ELD 明确报错，不能保证 iPhone 镜像有声音 |
| Linux 桌面 | GTK 3、FFmpeg 6+、PulseAudio 兼容音频服务和 Avahi 等系统依赖；H.264、AAC-LC、有限 AAC-ELD、ALAC 实现，真实 iPhone 播放仍需验证 |

## 使用

1. 将 iPhone 与接收设备连接到同一局域网。
2. 打开应用，默认自动接收。如出现局域网访问提示，允许访问。自动接收可在设置中关闭。
3. 在 iPhone 控制中心打开“屏幕镜像”，选择首页显示的设备名。
4. 收到画面后自动进入播放页。手机与 TV 自动隐藏系统栏，手机方向跟随画面；macOS 窗口跟随画面比例。
5. 点击画面、移动鼠标或按遥控器显示控件。“断开投屏”结束当前投屏后恢复待命；当前通过停止并重启接收器实现。
   要完全停止接收，使用首页的“接收投屏”开关；TV 关闭接收后可通过首页的“打开接收”恢复。

接收中可修改设备名，保存后自动重启；当前投屏会结束。Android 使用前台服务，退到后台或关闭界面后继续接收，
通知提供“打开”和“停止接收”入口。Android 13+ 请允许通知，以便从后台连接提醒进入播放页。
Android 10+ 如需收到投屏时自动打开应用，可在设置中进入系统授权页，允许显示在其他应用上层；
部分设备还需在“应用权限与通知”中允许后台弹出界面。系统不允许自动打开时，点击连接通知进入应用。
Android 8–9 会在后台收到连接时尝试自动打开应用。
系统强行停止应用或终止服务后，需要重新打开应用恢复接收。
手机仅在应用前台接收期间保持常亮，TV 在应用前台期间保持常亮。
iPad 需要保持应用在前台并允许本地网络访问；返回前台恢复此前开启的接收状态，
发送端可能需要重新连接。iPad 不提供后台空闲待命。

## 操作与设置

macOS 顶部按钮提供关闭、最小化和全屏。可拖动标题区域移动窗口，双击切换全屏。
播放时顶部按钮随播放控件一起隐藏，窗口大小跟随画面比例。

macOS 支持 `⌘R` 启停、`⌃⌘F` 全屏、`⌘,` 设置、`⌘L` 日志、`⌘.` 断开，`Esc` 退出全屏。
播放控件在鼠标静止 2.5 秒后隐藏；双击画面切换全屏。
手机控件 3 秒后隐藏。Back 优先隐藏控件；控件隐藏时按 Back 显示断开提示，2 秒内再次按 Back 才断开。
TV 按 OK / 方向键 / Menu 显示控件，默认焦点为“继续观看”，5 秒后隐藏；Back 只显隐控件，不断开投屏。
TV 设置使用全屏页面，待命首页默认聚焦“设置”，关闭或出错时聚焦“打开接收”或“重试”。

macOS 支持菜单栏驻留、播放置顶、防止显示器休眠、连接时显示窗口及可选全屏。
默认关闭窗口后继续驻留接收；关闭播放窗口会先断开投屏。登录启动使用 macOS 13+ 的系统服务。
发送端名称来自接收协议，缺失时使用 iPhone。菜单栏与 Flutter 共用中英文资源。

若设备无法被发现，先确认接收器处于等待状态、两端网络可互通，并查看应用日志。
“可被发现”表示服务已启动，不证明 iPhone 一定能发现它。
连接提示表示发送端已连接，收到视频画面后才进入播放页。

应用日志通过 `mixin_logger` 自动写入文件，最多保留 10 个文件，每个 5 MiB。
macOS 位于 `~/Library/Application Support/org.flutterairplay.receiver/logs/`；
Android 位于应用外部文件目录 `Android/data/io.github.boyan01.flutter_airplay/files/logs/`。
文件包含 Flutter、接收核心和播放诊断，重启后保留。日志页“清空”只清空当前显示。

开发环境、构建与测试命令见 [AGENTS.md](AGENTS.md)。
实验性宿主的构建和限制见 [iPad](ios/README.md)、[Windows](windows/README.md)
与 [Linux](linux/README.md)。

## 分发与许可

macOS 应用采用 VideoToolbox / CoreAudio，Android 采用 NDK MediaCodec / Oboe。
macOS 音频使用 AudioConverter 解码；Android 的 AAC / AAC-ELD 使用 MediaCodec，ALAC 使用内置专用解码器。
OpenSSL 和 libplist 静态链接到共享播放库。
macOS 可以打包为独立运行的 `.app` 与 ZIP，当前使用本地 ad-hoc 签名、非沙箱运行。
面向互联网分发仍需 Developer ID 签名和公证；首次运行时应允许局域网访问。
应用不会修改系统 AirPlay Receiver、防火墙、系统音量或凭据。

项目使用 [GPLv3](LICENSE)。分发时保留第三方版权与许可声明，并履行相应源码义务。
第三方来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，
UxPlay 上游版本与基准 commit 见 [UPSTREAM.md](vendor/UxPlay/UPSTREAM.md)。

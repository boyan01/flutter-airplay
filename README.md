# Flutter AirPlay

一个 GPLv3 开源的 AirPlay 接收器，用于在同一局域网内接收 iPhone 屏幕镜像。
macOS 和 Android 共用 Flutter 界面、UxPlay 接收协议与 C++ 播放核心；
Windows、Linux 和 iPad 宿主复用同一工程，当前属于实验性平台支持。
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
| macOS | macOS 12+、Apple Silicon；支持 H.264，HEVC 硬解可用时宣告 HEVC 支持；应用包内置依赖，无需安装 Homebrew 或 GStreamer |
| Android 手机 | Android 8.0（API 26）及以上，当前仅打包 arm64-v8a；H.264，选定尺寸的 60 FPS HEVC 硬解可用时宣告 HEVC 支持 |
| Android TV | 共用 Android 应用和 HEVC 能力检测，提供 TV 布局与遥控器方向键操作，当前仅打包 arm64-v8a |
| iPad | iPadOS 15+，前台接收 H.264、ALAC、AAC-LC、AAC-ELD；HEVC 硬解可用时宣告 HEVC 支持；切到后台停止接收 |
| Windows | Windows 10+ x64；H.264、HEVC、ALAC、AAC-LC、有限 AAC-ELD；HEVC 优先系统解码，包内 FFmpeg 提供软件备用路径 |
| Linux 桌面 | GTK 3、FFmpeg 6+、PulseAudio 兼容音频服务和 Avahi 等系统依赖；H.264、HEVC 软件解码，AAC-LC、有限 AAC-ELD、ALAC 实现 |

Windows 的 H.264 播放在 Windows N 上需要 Media Feature Pack。HEVC 软件备用路径
无需额外安装系统 HEVC 扩展，但流畅度取决于 CPU，不保证 4K 60 FPS。
Windows 与 Linux 的 Main10 画面输出为八位 RGBA，目前不提供 HDR tone mapping。
两者的 AAC-ELD 支持常见 480/512 样本帧，不支持 LD-SBR 和部分 ER 工具；
音频输出为 44.1 kHz 双声道。持续播放、音频设备变化和音画同步仍需按目标设备验证。

iPad 音频中断或输出路由变化会结束当前连接并重建接收，需要发送端重新连接。
Linux 需要正常运行的 Avahi、系统 D-Bus 和 PulseAudio/PipeWire 音频服务。
发现服务发布失败时显示错误；音频输出不可用时在音频会话开始后报告失败。

Linux 托盘需要支持 AppIndicator 的桌面环境。没有托盘宿主时，关闭窗口会退出；
托盘宿主消失且窗口隐藏时，应用重新显示窗口。Linux 不提供登录启动，
Wayland 对窗口激活、位置、比例和置顶的限制取决于 compositor。

## 使用

1. 将 iPhone 与接收设备连接到同一局域网。
2. 打开应用，默认自动接收。如出现局域网访问提示，允许访问。自动接收可在设置中关闭。
3. 在 iPhone 控制中心打开“屏幕镜像”，选择首页显示的设备名。
4. 收到画面后自动进入播放页。手机与 TV 自动隐藏系统栏，手机方向跟随画面；macOS 和 Windows 窗口跟随画面比例。
5. 点击画面、移动鼠标或按遥控器显示控件。“断开投屏”结束当前投屏后恢复待命；当前通过停止并重启接收器实现。
   要完全停止接收，使用首页的“接收投屏”开关；TV 关闭接收后可通过首页的“打开接收”恢复。

设备名支持随机生成和重置为系统默认名。名称、清晰度和音频输出等接收设置自动保存：
等待连接时自动应用；已有连接时保留当前投屏，连接结束后统一应用最新设置。接收关闭时只保存，不会自动开启。

Android 使用前台服务，退到后台或关闭界面后继续接收，
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
Windows 内容覆盖标题栏，右侧提供最小化、最大化/还原和关闭；双击标题区最大化/还原。
两个桌面平台的顶部按钮随播放控件一起隐藏，窗口大小跟随画面比例。

macOS 支持 `⌘R` 启停、`⌃⌘F` 全屏、`⌘,` 设置、`⌘L` 日志、`⌘.` 断开，`Esc` 退出全屏。
Windows 对应使用 `Ctrl+R`、`F11`、`Ctrl+,`、`Ctrl+L`、`Ctrl+.`，`Esc` 退出全屏；
`Ctrl+W` 关闭窗口，`Ctrl+Q` 退出程序。
播放控件在鼠标静止 2.5 秒后隐藏；双击画面切换全屏。
手机控件 3 秒后隐藏。Back 优先隐藏控件；控件隐藏时按 Back 显示断开提示，2 秒内再次按 Back 才断开。
TV 按 OK / 方向键 / Menu 显示控件，默认焦点为“继续观看”，5 秒后隐藏；Back 只显隐控件，不断开投屏。
TV 设置使用全屏页面，待命首页默认聚焦“设置”，关闭或出错时聚焦“打开接收”或“重试”。

Android 手机和 TV 可在设置中选择“适配本机”、720p、1080p、1440p 或 4K。
默认“适配本机”参考屏幕像素和解码能力，最高请求 2160p；解码器不支持的档位不可选。
设置中显示屏幕像素与实际收到的画面尺寸。发送端决定最终尺寸，选择档位不保证逐像素匹配屏幕。
修改清晰度后，等待连接时自动生效；已有连接时，在连接结束后自动生效。

macOS 提供相同清晰度档位，“适配本机”参考播放窗口所在屏幕的实际像素。
移动窗口不会中断投屏，新的屏幕信息在下次启动接收器时用于请求画质。
视频编码由发送端协商选择，选择高分辨率不保证发送端采用 HEVC 或达到 60 FPS。
各平台日志中的 `Video codec selected` 和解码器记录可以确认实际编码。
macOS 和 iPad 使用 VideoToolbox 硬解，Android 手机和 TV 使用 MediaCodec 硬解。
Windows 优先使用系统同步 Media Foundation HEVC decoder，无法配置时使用包内 FFmpeg；
Linux 使用系统 FFmpeg。软件解码的流畅度取决于 CPU、视频尺寸与帧率。

Android 视频统一使用原生 SurfaceView，在应用页面内播放，Flutter 负责首页、设置和播放控制。
画面保持原始比例，系统刷新率不强制切换；离开应用后继续后台接收，返回时恢复画面。
Android 设置页显示版本及构建时间（UTC），导出的诊断信息也包含构建时间与显示方式。

macOS 支持菜单栏驻留，Windows 支持托盘驻留。两个平台均支持播放置顶、防止显示器休眠、
连接时显示窗口及可选全屏。默认关闭窗口后继续驻留接收；关闭播放窗口会先断开投屏。
登录启动默认关闭，macOS 使用 macOS 13+ 的系统服务，Windows 使用当前用户的 Run 项。
发送端名称来自接收协议，缺失时使用 iPhone。菜单栏、托盘与 Flutter 共用中英文资源。

若设备无法被发现，先确认接收器处于等待状态、两端网络可互通，并查看应用日志。
“可被发现”表示服务已启动，不证明 iPhone 一定能发现它。
连接提示表示发送端已连接，收到视频画面后才进入播放页。

应用日志通过 `mixin_logger` 自动写入文件，最多保留 10 个文件，每个 5 MiB。
macOS 位于 `~/Library/Application Support/tech.soit.flutterairplay/logs/`；
Android 位于应用外部文件目录 `Android/data/tech.soit.flutterairplay/files/logs/`。
文件包含 Flutter、接收核心和播放诊断，重启后保留。日志页“清空”只清空当前显示。

各平台的开发环境、运行、构建、测试与打包命令统一见 [开发指南](DEVELOPMENT.md)。
项目开发约定见 [AGENTS.md](AGENTS.md)。

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

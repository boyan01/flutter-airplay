# Windows 宿主

Windows 实现继续运行根目录 `lib/main.dart` 和共享 C++ 播放器。当前代码使用
Windows 10+ 的 Media Foundation H.264、共享 FFmpeg AAC 解码、内置 Apple ALAC、WASAPI
和系统 DNS-SD；窗口内的 Flutter 纹理显示镜像，不创建额外播放器窗口。

当前仍属于实验性支持。AAC-ELD 使用有限配置，持续播放、设备变化和音画同步
仍需按目标设备验证。

```text
+--------------------------------------------------+
| Flutter AirPlay (drag / double-click)  [_] [ ] [X]|
|                                                  |
|          Existing waiting / mirrored page        |
|                                                  |
| [Receive: ON]                    [Settings]      |
+--------------------------------------------------+
Notification area: [AirPlay] -> Open / Receive / Settings / Quit
```

## 构建

在 Windows x64 的 Visual Studio 2022 Native Tools 环境安装 C++ 桌面开发、
Windows 10/11 SDK、Visual Studio Clang tools、CMake、Git、Perl 和 MSYS2 GNU Make
（在 MSYS2 中运行 `pacman -S make`）。
原生库使用 ClangCL 编译 C 接收核心并生成兼容 MSVC 的 DLL/import library；
Flutter 宿主继续使用标准 Windows 工具链。线程与 socket 兼容层不依赖
pthread DLL 或 Apple Bonjour DLL。FFmpeg 源码构建使用 MSYS2 Bash 和 GNU Make，
通过 `-Bash`、`-Make` 指定工具路径，也可使用 Git Bash 搭配兼容的 MSYS2 Make。
Strawberry Perl 附带的原生 Windows Make 不支持这套 POSIX 构建路径。
不需要安装 FFmpeg 命令行程序。

从仓库根目录运行固定版本 Flutter，再构建原生库和宿主：

```powershell
fvm flutter pub get
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build_native.ps1 -Tests -Bash C:/msys64/usr/bin/bash.exe -Make C:/msys64/usr/bin/make.exe
fvm flutter build windows --release
```

脚本从 `android/dependencies.lock.json` 获取固定 OpenSSL / libplist / FFmpeg 源码并核对
commit，使用 `vendor/UxPlay/` 和 `vendor/alac/`。FFmpeg 仅构建原生浮点 AAC decoder
与 `avcodec`、`avutil`、`swresample` DLL，不启用 GPL/nonfree 组件或外部 codec。
依赖和构建产物位于 ignored `build/windows-deps/`、`build/windows-native/`。
Flutter 打包在原生 DLL 或 FFmpeg 运行时缺失时会失败。
包内保留许可证、固定源码来源与构建配置。
构建脚本不下载预编译 codec，不修改防火墙。

## 当前媒体范围

- H.264：系统同步 MFT 输出 NV12，由 CPU 转 RGBA 后接入 Flutter
  `PixelBufferTexture`。支持码流参数变化、解码队列 generation 和 FLUSH。
  当前不声称 GPU 解码、零拷贝或 60 FPS 性能已验证。
- ALAC：复用现有内置 decoder 和 AirPlay 配置；共享 PCM 队列输出至 WASAPI。
- AAC-LC / AAC-ELD：与 Linux 共用 `native/player/ffmpeg_audio_decoder.cpp`。
  产品当前输出为 44.1 kHz、双声道 S16 PCM；ELD 使用 480/512 样本帧，不支持
  LD-SBR 或部分 ER 工具。AAC-LC 960 配置可接受，现有正向 fixture 覆盖 1024。
  RAOP TXT 声明 `cn=1,2,3`。
- WASAPI：共享模式使用系统采样率转换；默认输出设备变化和失效后重开。
  AAC-LC 播放、输出设备变化、设备延迟与音画同步仍需 Windows 验证。
- Windows N 的 H.264 播放需要 Media Feature Pack。AAC 解码使用包内 FFmpeg。

## 发现与生命周期

使用 Windows `DnsServiceRegister` 发布 `_airplay._tcp` / `_raop._tcp`，等候
异步注册结果后才进入等待状态。停止时撤销服务，保留本地随机 identity 与
配对密钥。配置只写当前用户的 LocalAppData 目录。接收核心的 `int` descriptor
映射到全宽 Windows `SOCKET`，避免 x64 句柄截断；原生线程退出前加入所有工作。

Flutter 内容覆盖标题栏，使用 Windows 布局的最小化、最大化/还原和关闭按钮。
拖动标题区移动窗口，双击最大化/还原。窗口保留原生边缘缩放和 Windows 窗口
吸附；播放时按视频方向调整窗口，缩放时保持视频比例。全屏保存并恢复窗口
placement / style。播放控制条和标题按钮随现有播放浮层一起隐藏。

托盘显示接收状态，提供打开窗口、启停接收、断开、设置、日志和退出。视频
播放时还提供全屏、实际大小、适合屏幕和置顶。默认关闭窗口后留在托盘；若
正在投屏，关闭窗口会断开当前会话并恢复等待。关闭“关闭窗口后保留在托盘”
后，关闭按钮会退出程序。再次运行程序会打开现有实例。

设置复用 macOS 的桌面选项：登录启动、关闭后保留、连接时显示窗口、连接时
进入全屏、播放时置顶。登录启动仅写当前用户的 Run 项，默认关闭。连接时
自动打开的窗口在视频结束后自动隐藏；手动打开的窗口继续显示。视频播放
期间请求系统保持显示和唤醒，结束后释放。托盘在 Explorer 重启后重新注册。

键盘支持 `Ctrl+R` 启停接收、`Ctrl+,` 设置、`Ctrl+L` 日志、`Ctrl+.` 断开、
`Ctrl+W` 关闭窗口、`Ctrl+Q` 退出、`F11` 切换全屏和 `Esc` 退出全屏。

## 验证入口与缺口

`build_native.ps1 -Tests` 构建并执行：

- `windows_pixels`：合成 NV12 的黑/白/红色、BT.601 / BT.709、limited / full
  range、行填充和畸形缓冲输入。
- `windows_compat`：Windows UDP loopback、descriptor/fd_set 映射、可加入线程
  和带锁 condition wait。
- `windows_httpd`：HTTP 监听器初始化、TCP loopback 请求响应和两次启动/销毁，
  覆盖生命周期锁必须显式初始化的 Windows 要求。
- `windows_audio_decode_recovery`：Windows/Linux 共用的 ALAC、AAC-LC、ELD 480/512
  PCM 回归，检查包期限、坏包、截断、FLUSH、队列饱和、格式拒绝和恢复。

像素转换 fixture 可在 macOS 用 C++17 与 ASan/UBSan 独立运行。该结果只证明
颜色转换与缓冲边界逻辑，不证明 Windows MFT、WASAPI、DNS-SD 或 Flutter 纹理。
Windows 仍需完整 codec fixture，以及真实 iPhone 的音频、持续播放、暂停恢复、
断开重连、尺寸方向变化和网络变化验证。正常接收流量所需的 Windows
防火墙策略由用户/部署环境配置，本代码不自动更改系统网络规则。

API 依据：[AAC decoder](https://learn.microsoft.com/en-us/windows/win32/medfound/aac-decoder)、
[H.264 decoder](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder)、
[Windows DNS-SD](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsserviceregister)、
[Flutter texture registrar](https://api.flutter.dev/windows-embedder/flutter__texture__registrar_8h_source.html)、
[DWM custom frame](https://learn.microsoft.com/en-us/windows/win32/dwm/customframe)、
[Notification area](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area)。

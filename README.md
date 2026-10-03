# Flutter AirPlay

GPLv3 开源 iPhone 投屏接收器：Flutter 负责设备名、启动/停止、状态与日志，
Swift 管理 UxPlay 子进程，并将 GStreamer 解码帧显示为 FlutterTexture；音频由 macOS 播放。
应用内预览支持全屏与横竖屏比例变化；macOS 产品只维护内嵌显示路径。
只面向同局域网；不支持 DRM 内容，不承诺点对点连接。

## 本机直接运行

本机先按下方步骤构建，然后运行：

```sh
open "build/macos/Build/Products/Release/Flutter AirPlay.app"
```

在界面点击“启动接收”，允许 macOS 局域网访问提示（如果出现）。
iPhone 与 Mac 连接同一局域网，打开控制中心 → 屏幕镜像 → 选择界面中的设备名。
默认在应用内预览画面；点击预览右上角展开，Esc 返回，也可用 macOS 窗口全屏按钮。
声音由 Mac 播放。
点击“停止接收”、关闭主窗口或退出主应用会清理接收进程与本地帧通道。
设备名与可选的核心路径保存在本应用自己的 UserDefaults；停止后可修改。

## 从源码构建

要求 macOS、Flutter stable 与可用的 Xcode macOS SDK。Apple Silicon 本机已验证；Intel 未验证。
本机用 Homebrew（上游也推荐官方 GStreamer runtime + devel framework）：

```sh
brew install cmake pkg-config libplist openssl@3 gstreamer
./scripts/build_receiver.sh
flutter pub get
flutter run -d macos
# Or:
flutter build macos
```

无需 sudo make install，UxPlay 只编译至项目内，再复制到 app 的 Resources/receiver。
项目包含固定 UxPlay v1.73.7 上游源码，SHA-256 清单在 native/uxplay.lock.json。
构建时验证源码并将 native/patches 补丁应用到 build/uxplay-src；不修改 vendor 原件。原生核心修改后必须重跑
build_receiver.sh，并重构建应用。高级核心路径应指向本项目带事件补丁的 uxplay；普通
Homebrew uxplay 不提供事件协议，会明确报告启动超时。

## 验证

```sh
flutter analyze
flutter test
./scripts/test_native.sh "$PWD/native/receiver/uxplay"
./scripts/test_frames.sh # Appsink/socket/CVPixelBuffer lifecycle and malformed/slow-reader checks
./scripts/test_audio.sh # This machine: Homebrew, synthetic ALAC to fakesink
./scripts/test_sync.sh # Synthetic real renderers: shared clock + PTS scheduling
./scripts/test_rtp.sh # Real loopback RTP stream restart epoch
./scripts/test_recovery.sh # Bad timestamps, same-codec SETUP and FLUSH recovery
```

结果和实测范围见 [docs/VALIDATION.md](docs/VALIDATION.md)。

## 实现边界

- Flutter 的 ReceiverModel / ReceiverRepository 与 Swift 原生 Process 边界分离。
  macOS 使用软件 H.264 解码 → BGRA appsink → 有界私有 Unix socket → IOSurface
  CVPixelBuffer → FlutterTexture。接收和原生音频/时钟保持独立；目前会复制像素，
  未实现 VideoToolbox 硬件解码或零拷贝。大尺寸流的 CPU/内存/可见延迟仍需真机测量。
- ready 表示接收器已创建服务并提交 Bonjour 注册。streaming 只在 UxPlay 收到非空
  音频/视频数据后触发；并不证明视频已经成功解码、所有帧已显示或声音可听。
  断开/网络重置回到 waiting。日志保留最多 300 行，不落盘，复制日志前可自行查看内容。
- 原生层幂等启动，停止先 SIGTERM，3 秒后仅对自己拥有的 PID 使用 SIGKILL。
  正常关闭最后窗口 / Cmd-Q 清理接收进程。进程被强制杀死、系统崩溃的恢复未实现。
- 不使用固定端口，不启用 -p2p，不修改 macOS 自带 AirPlay Receiver、防火墙、签名账号
  或凭据。用 `-rc /dev/null` 隔离用户自己的 UxPlay 配置；不使用持久配对密钥或注册文件。

## 已验证与后续工作

原型已由用户确认真实 iPhone 能显示画面和播放音频。首轮连接曾遇到旧 osxvideosink
崩溃，原型曾使用软件 H.264 解码 + glimagesink 绕开该路径；当前应用改为内嵌 appsink。
恢复共享时钟同步，并修复
音频重新 SETUP 时复用旧 RTP 时间基准导致停止出声的问题；合成回归覆盖恢复行为。
真实设备长时间播放、切视频、暂停/拖动及多次重连仍需要继续验收。

FlutterTexture 内嵌路径已通过实际 H.264 renderer 合成帧与 CUA 可见横竖屏、全屏、
启停和退出检查。这些合成结果不能代表新版真实 iPhone 音画/同步/稳定性验收。
新版有真实 iPhone 连接及解码事件，但用户的音画确认仍待记录；观察到 IPv6 NTP
“无路由”日志，未改变任何系统网络设置。Android 在独立工作流开发，尚未集成到本应用；
参考项目或独立基础模块不代表当前应用已经支持 Android。

## 打包与权限限制

当前 Debug/Profile/Release 都是本机开发用的非沙箱应用，用于启动 UxPlay helper 和
读取本机 Homebrew 动态库/插件。Info.plist 包含局域网用途与 Bonjour 服务声明。
Terminal 启动与 Finder/LaunchServices 启动的 Release app 权限归因可能不同，
CLI ready 不能代替真机发现、连接、画面及声音验收。

app 中的 arm64 核心仍依赖 /opt/homebrew；不能作为独立安装包复制给没有依赖的 Mac。
尚无 Developer ID 签名、公证、dmg、升级机制或沙箱 helper 集成，Intel 未验证。
后续分发必须处理依赖打包、许可、helper 签名和局域网权限。不会更改系统 AirPlay Receiver、
防火墙、系统音量、凭据或安全设置。

参考：[UxPlay 官方 macOS 指引](https://github.com/FDH2/UxPlay#building-uxplay-on-macos-intel-x86_64-and-apple-silicon-macs)、
[稳定版发布](https://github.com/FDH2/UxPlay/releases/tag/v1.73.7)。
许可与出处见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

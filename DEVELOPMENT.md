# 开发指南

所有平台使用根目录的 Flutter 应用。本文是环境、运行、测试和打包命令的统一入口。
产品功能与平台限制见 [README.md](README.md)，代码修改约定见 [AGENTS.md](AGENTS.md)。

- [日常开发](#日常开发)
- [平台环境与原生构建](#平台环境与原生构建)
- [按改动选择验证](#按改动选择验证)
- [自动化测试](#自动化测试)
- [测试素材与诊断](#测试素材与诊断)
- [打包与分发](#打包与分发)
- [资源与内部脚本](#资源与内部脚本)

## 日常开发

命令均从仓库根目录执行，默认使用最新的 Flutter stable SDK。确保 PATH 中的 `flutter`
来自 stable 通道；切换通道或更新 SDK 时执行 `flutter channel stable` 和 `flutter upgrade`。
会在内部调用 Flutter 的脚本也使用 PATH 中的 SDK。首次设置或依赖变化后执行：

```sh
flutter pub get
flutter devices
```

安装下节对应平台的工具链后，直接运行；Flutter 平台构建会自动准备原生产物：

| 目标 | 日常运行 |
| --- | --- |
| macOS | `flutter run -d macos` |
| Android 手机 / TV | `flutter run -d <device-id>` |
| iPad / iPad 模拟器 | `flutter run -d <device-id>` |
| Windows | `flutter run -d windows` |
| Linux | `flutter run -d linux` |

`<device-id>` 替换为 `flutter devices` 列出的目标。默认使用 Debug，Dart UI 改动优先热重载。
原生源码、依赖和构建配置未变且产物完整时直接复用；变化或产物缺失时自动重建。
原生代码变化后重新执行 `flutter run`；热重载只更新 Dart。首次构建需要联网下载固定依赖。
macOS / iPad 使用 Xcode scheme 预构建，Android 使用 Gradle `preBuild`，Windows 使用 CMake，
Linux 继续使用已有 CMake 构建。以下独立脚本保留用于原生调试和构建测试 fixture，无需在日常运行前手动执行。
当前独立原生构建脚本使用优化配置；这不要求 Flutter 应用也使用 Release。

日常迭代只检查受影响流程或运行针对性测试。不要每次小改都构建所有平台、执行全部回归。
发布、包内容检查和 Release 特有问题才进入[打包与分发](#打包与分发)。

## 平台环境与原生构建

### macOS

当前原生构建要求 Apple Silicon Mac、Xcode macOS SDK、CMake、Python 3 和 Perl。
Intel 构建未验证。缺少 CMake 时可通过 `brew install cmake` 安装。

```sh
./scripts/build_receiver.sh
```

脚本读取 `android/dependencies.lock.json` 校验源码，构建共享 C++ 播放器及静态 OpenSSL、
libplist，输出到 `build/macos-native/`。Xcode 负责链接与打包，系统提供 VideoToolbox、
AudioConverter、CoreAudio 和 Bonjour。

### Android 手机与 TV

原生脚本支持 macOS 和 Linux x86_64，要求 Android SDK、SDK CMake `3.22.1`、
Python 3、Perl 和 Make。Linux 可用 `sudo apt-get install build-essential cmake ninja-build perl python3 libssl-dev`
准备构建与 host 测试依赖。应用最低 API 26，只打包 arm64-v8a；
运行目标应为 arm64 设备。

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
# On Linux, use the SDK installation path, typically $HOME/Android/Sdk.
sdkmanager "ndk;$(sed -n 's/^airplay\.ndkVersion=//p' android/gradle.properties)" 'cmake;3.22.1'
./android/scripts/build_native.sh
```

SDK 安装在其他位置时修改 `ANDROID_HOME`，也兼容已有 `ANDROID_SDK_ROOT` 配置。
NDK 版本统一由 `android/gradle.properties` 的 `airplay.ndkVersion` 指定，Gradle、原生脚本和 CI
共用它。升级 NDK 时修改这一项并验证原生构建与播放。
原生与 OpenSSL 构建目录按 NDK 版本隔离，避免升级后复用旧工具链产物。
依赖缓存位于 `android/.cache/`，原生输出位于 `build/android-native-arm64-<ndk-version>/`，JNI 库复制到
`android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so`。缺失 JNI 库时应用打包会失败。

### iPad

要求 Apple Silicon Mac、Xcode、CMake、Python 3、Perl；目标为 iPadOS 15+。

```sh
./ios/scripts/build_native.sh
```

脚本分别构建设备和 arm64 模拟器静态库，再生成
`build/ios-native/AirplayPlayer.xcframework`，目前没有 Intel 模拟器归档。
设备运行需在 Xcode 的 `ios/Runner.xcworkspace` 中配置自己的签名团队；
仓库不保存个人签名账户。无签名构建只能验证编译，不能安装到设备。

### Windows

Windows x64 构建自动加载 Visual Studio 2022 x64 工具环境。安装 C++ 桌面开发、
Windows 10/11 SDK、Visual Studio Clang tools、CMake、Git（含 Git Bash）、Python 3.10+ 和 Perl。
工具必须能从当前终端访问。缺少兼容 GNU Make 时，原生构建会自动下载 lock 文件中的
MSYS2 版本并校验 SHA-256，缓存至 `windows/.cache/tools/`，不受 `flutter clean` 影响。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build_native.ps1
```

默认检测 MSYS2 或 Git Bash，以及可用的 MSYS2/Cygwin GNU Make；也可通过
`AIRPLAY_BASH` / `AIRPLAY_MAKE` 环境变量指定路径，
供 `flutter run` 自动构建使用；独立脚本仍支持 `-Bash` / `-Make`。Python 必须可通过 `python` 执行。
路径按本机安装位置调整。FFmpeg 要求支持 POSIX 路径的 MSYS2/Cygwin GNU Make，
Strawberry Perl 附带的原生 Windows Make 不适用。
脚本使用 ClangCL、固定版本的 OpenSSL / libplist / FFmpeg 源码和共享接收核心，
输出至 `build/windows-deps/` 与 `build/windows-native/`。
系统提供 Media Foundation、WASAPI 和 DNS-SD；软件解码备用路径使用包内 FFmpeg，
无需额外安装 FFmpeg 命令行工具。`-Tests` 只构建测试 fixture，执行测试使用下文的统一 native 入口。

### Linux

在 Linux 上安装 GTK 3、FFmpeg 6+（`libavcodec >= 60`）、PulseAudio 兼容音频服务、
Avahi、Ayatana AppIndicator 3、OpenSSL 和 libplist 2.3+ 的开发包。
Debian 13 可使用：

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev \
  libpulse-dev libavahi-client-dev libayatana-appindicator3-dev \
  libssl-dev libplist-dev libx11-dev libxi-dev
```

`flutter run -d linux` 会通过 CMake 一并构建原生代码，无需独立原生构建步骤。
运行时需要可用的系统 D-Bus、`avahi-daemon` 和 PulseAudio/PipeWire 输出服务。
应用不会代为启动系统服务或调整防火墙。配置和配对数据位于
`$XDG_CONFIG_HOME/flutter-airplay`，通常为 `~/.config/flutter-airplay`。

## 按改动选择验证

| 改动 | 适合的检查 |
| --- | --- |
| 文档 | `git diff --check`、文档链接和命令路径 |
| Dart 逻辑 | `flutter analyze`、相关 `test/` 文件 |
| UI / 输入 | `flutter run` 中的受影响流程，窄/宽布局和相关触摸、键盘、TV 焦点；需要长期保护的行为增加 widget 测试 |
| 平台宿主 | 受影响平台编译和对应宿主测试 |
| 共享协议 / 播放核心 | 在完成节点或 CI 中运行相关原生回归，并检查受影响平台编译 |
| 依赖 / 打包 | 对应平台包、运行时依赖和许可证检查 |

共享功能完成时检查各平台实现是否同步，在可用目标上验证相关流程。
通过的检查可复用，后续改动影响其输入、出现失败或仍有风险时再补跑。
[GitHub Actions](.github/workflows/ci.yml) 承担提交后的格式、静态检查、Dart 测试及相关平台
编译与自动化回归。日常开发复用仍有效的本地结果，并查看当前提交的 CI 结果。

报告实际执行的检查、测试输入和剩余缺口。合成媒体、编译成功与接收状态事件不能证明
真实 iPhone 发现、画面、可听声音或音画同步。相关改动仍需要真实设备验证。

## 自动化测试

日常测试只有两类入口：

```sh
flutter test
./scripts/test_native.sh
```

Dart 使用 Flutter 自带命令，无需额外脚本。Native 入口默认运行当前开发机的基础回归，
完整宿主、额外 codec、设备、模拟器和 GUI 检查需通过参数显式选择。
查看全部参数使用 `./scripts/test_native.sh --help`。构建、打包和资源生成属于其他操作，
使用前文和后文的对应命令。
原生自动构建入口的缓存、源码/依赖变化、产物缺失与失败恢复检查使用 `./scripts/test_native.sh build`。

### GitHub Actions

`CI` 在 PR 和推送到 `main` 时运行，也可在 Actions 页面手动启动全部平台任务。
各平台使用最新的 Flutter stable，依赖安装校验 `pubspec.lock`，应用编译统一使用 Debug。
独立原生脚本仍使用自身的优化配置。

| 任务 | 覆盖 |
| --- | --- |
| Format, analyze and Dart tests | workflow 的 actionlint、原生构建入口回归、Dart format 检查、`flutter analyze --fatal-infos`、完整 `flutter test` |
| macOS | 原生构建、Debug 应用编译、player/host/texture/RTP 回归 |
| Linux | Debug 应用编译、完整 native suite、Xvfb 中的 GTK/托盘及真实标题拖动、独立 ALAC decoder |
| Windows | 原生及 Debug 应用编译、像素、兼容层、HTTP 生命周期、音频恢复、平台及 FFmpeg 视频回归 |
| Android | arm64 JNI 与 Debug APK 编译、host 协议测试、Kotlin 单元测试 |
| iPad | 设备/模拟器原生归档、模拟器 Debug 应用、iPad 模拟器 XCTest |

轻量检查每次运行。共享代码、依赖、资源或 workflow 变化会触发全部平台；
平台专用目录变化触发对应平台任务；其他平台也引用的 Android C++ 和依赖配置按共享代码处理。
纯 Markdown 文档改动只跑轻量检查。
平台任务在轻量检查通过后开始，同一 PR/分支的新运行会取消旧运行。
失败时保存已有测试日志或 XCTest 结果，保留 7 天。

macOS 和 iPad 使用 Apple Silicon runner，Android 编译及 host/Kotlin 测试使用 Ubuntu x86_64 runner。
Linux 的窗口测试在隔离 X11 显示和 session bus 中运行。
Windows Server runner 会检查并启用 Media Foundation，软件解码使用项目构建的 FFmpeg。
Android 播放器 fixture 与应用集成测试要求 arm64 设备，目前不在托管 CI 中运行；
macOS 全屏窗口测试、真实投屏发现、设备音频/视频输出及音画同步仍需目标设备验证。
CI 的编译与合成媒体结果不能替代这些检查。

GitHub 托管 runner（`GITHUB_ACTIONS=true` 且 `RUNNER_ENVIRONMENT=github-hosted`）
跳过 macOS 的 30ms 实时到达抖动断言和 Linux 的真实 Flutter 标题拖动/关闭测试：
虚拟主机调度不能保证实时上限，Xvfb 下的拖动路径出现 GDK event device 错误。
跳过时输出明确的 `SKIP` 原因；其他视频、暂停恢复、GTK/托盘生命周期测试照常运行。
本地及 self-hosted runner 保留这两项检查。

### Dart

```sh
flutter analyze
flutter test test/receiver_repository_test.dart
# Run the full Flutter suite at a suitable checkpoint.
flutter test
```

Kotlin 状态适配层属于 Android native 检查，使用已配置的 `GRADLE_BIN` 和 JDK：

```sh
./scripts/test_native.sh android kotlin
```

### 原生协议与播放

| 测试对象 | 命令 | 前置条件与覆盖范围 |
| --- | --- | --- |
| macOS 共享播放器 | `./scripts/test_native.sh macos player` | 已有最新 `build/macos-native/`；C++ 时钟、PCM 队列、音视频解码、会话和 loopback |
| macOS 接收宿主 | `./scripts/test_native.sh macos host` | 已构建原生播放器；Swift 宿主、接收回调与生命周期 |
| macOS 纹理适配 | `./scripts/test_native.sh macos texture` | 已构建原生播放器；帧与 Flutter 纹理适配 fixture |
| RTP / 协议边界 | `./scripts/test_native.sh macos rtp` | 已构建 macOS 原生输出；参数解析和畸形输入 |
| 独立 ALAC decoder | `./scripts/test_native.sh alac` | Clang/Clang++；bit-exact PCM、坏包与恢复；可加 `ALAC_SANITIZE=ON` |
| FFmpeg 视频适配 | `./scripts/test_native.sh ffmpeg` | FFmpeg 6+ 开发库、pkg-config、ffmpeg/ffprobe、Python 3；H.264/HEVC、重排与恢复；可加 `FFMPEG_SANITIZE=ON` |
| Android 接收核心 host | `./scripts/test_native.sh android host` | CMake、系统 OpenSSL 开发包；macOS Homebrew 可加 `HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)"`；loopback 协议与 DNS/TXT 适配；可加 `HOST_SANITIZE=ON` |
| RTP 的另一 host 配置 | `./scripts/test_native.sh android rtp` | 与 Android host 使用相同环境、与 macOS RTP 复用同一测试源；用于对应 host/sanitizer 配置，按需选择 |
| Android 播放器 | `./scripts/test_native.sh android player` | 最新 JNI 库、授权 arm64 设备、JDK 17+、SDK build-tools 36.0.0、`android` CLI；默认选定 decoder 回归，`--full` 运行完整矩阵；独立 fixture app 保留接收应用 |
| iPad 播放器 | `./scripts/test_native.sh ios` | 原生 XCFramework、通过 `flutter run` 准备的模拟器 Debug 产物与已有 iPad 模拟器；结果写入 `artifacts/ios/` |
| Windows 基础 | `bash scripts/test_native.sh windows` | 已使用 `build_native.ps1 -Tests` 构建 fixture；像素、socket/thread、HTTP 生命周期与音频恢复 |
| Windows 视频 / 全部 | `bash scripts/test_native.sh windows video` / `windows all` | 显式检查平台及 FFmpeg 视频 decoder，或全部原生 fixture |
| Linux 基础 | `./scripts/test_native.sh linux` | Linux 开发依赖；时钟、PCM/音频、H.264 恢复、会话与 loopback；只构建相关 fixture |
| Linux 视频 / 宿主 / 全部 | `./scripts/test_native.sh linux video` / `linux host` / `linux all` | 视频矩阵需要 ffmpeg/ffprobe 和 Python 3；宿主需要 Flutter engine；all 包括可用的窗口/托盘测试 |

macOS 默认只运行 player，不重新编译 Swift 宿主/纹理 fixture；完整组合使用
`./scripts/test_native.sh macos all`，窗口测试仍单独选择。
只运行一个 CTest 用例可使用 `./scripts/test_native.sh macos player -R playback`。
Windows 接受 CTest 参数，Linux 的 player/video/host/all 分支接受 CMake 参数。
这些参数用于缩小验证范围，不会自动构建其他平台。

同一轮、相同配置只运行一份共享回归：RTP 从 macOS 或 Android host 配置中选择；
Linux 的 video/all 已覆盖独立 FFmpeg suite 使用的相同视频源码，无需再重复运行 ffmpeg。
不同平台 backend、编译配置或 sanitizer 的验证仍分别保留。

Android host 回归不等于 Android 产品的 JNI 播放宿主验证。
Android 播放器 fixture 检查 GPU SurfaceTexture 像素、音频解码和静音 Oboe 输出，
不验证 Flutter 页面、发现或真实发送端。默认只检查系统选定的 AVC/HEVC decoder，
保留横竖屏、暂停恢复、surface 切换、burst pacing 和 pending reset；可用的 Qualcomm
decoder 仍检查其重排回归。HEVC 默认检查横竖屏。
`./scripts/test_native.sh android player --full` 才枚举额外硬件/软件/低延迟 decoder、
pacing 的 1/3/9 帧批次以及 HEVC 4K/Main10。相位扫描仍属于专项诊断。
可用 `AIRPLAY_AUDIO_ONLY=1` 只运行音频分支。

iPad 先用 `flutter run` 完成模拟器 Debug 准备；只做编译时也可使用打包表中的
模拟器 Debug 命令。已有对应产物时直接复用，XCTest 会构建测试宿主。
可用 `IOS_TEST_DESTINATION` 指定已有模拟器，例如：

```sh
IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPad (A16),OS=latest' ./scripts/test_native.sh ios
```

模拟器缺少 HEVC 硬解时明确跳过对应测试。
Linux Flutter 宿主测试在 `linux/flutter/ephemeral/` 已有 engine 库时启用；
先通过 `flutter run` 生成，再选择 `linux host` 或 `linux all`。
显式选择 host 时缺少目标会失败；all 中未满足前置条件的测试需检查 CMake 跳过提示。

### 窗口、托盘与输入

| 目标 | 命令 | 前置条件 |
| --- | --- | --- |
| macOS | `./scripts/test_native.sh macos window` | `flutter run -d macos` 生成的 Debug 产物，以及已登录的 macOS GUI 会话 |
| Linux GTK 窗口/托盘 | `./scripts/test_native.sh linux all` | 已有 Flutter engine 库，额外安装 `xvfb`、`dbus-x11`；运行在隔离显示和 session bus 中 |
| Linux 实际标题拖动 | `./scripts/test_native.sh linux window` | 已有 Debug bundle，额外安装 `xvfb`、`dbus-x11`、`openbox`、`xdotool`；真实鼠标操作检查拖动后坐标及关闭 |

Linux 拖动测试可接收其他 bundle 路径：`./scripts/test_native.sh linux window <bundle-path>`。
隔离环境的窗口与合成托盘测试不能替代真实桌面环境兼容性验证。

### Android 应用集成测试

这类测试使用接收应用本身，保留其数据与权限；应在授权设备上运行。

| 入口 | 行为 |
| --- | --- |
| `integration_test/android_receiver_restart_test.dart` | 三次改名及三次立即停止/启动；检查 waiting、存活接收器与纹理。要求自动接收已开启；清理恢复原名称和自动接收设置，并停止接收 |
| `integration_test/android_video_quality_test.dart` | 清晰度保存、停止/启动后持久化、请求尺寸与已解码尺寸区分；清理恢复原名称、自动接收和清晰度，并停止接收 |

使用 `flutter run` 启动需要的测试入口：

```sh
flutter run -d <device-id> --target integration_test/android_receiver_restart_test.dart
```

从运行日志取得 Dart VM service URI。如果 URI 仅在设备端可达，使用 `adb forward` 映射端口，
保留 URI 中的认证路径。把本机可访问的完整 URI 放入 `RECEIVER_VM_SERVICE_URL`，再附加 driver：

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --use-existing-app="$RECEIVER_VM_SERVICE_URL"
```

这里使用 `--use-existing-app`，因为默认 `flutter drive` 流程会在清理时卸载应用，
安装失败时也可能尝试卸载。运行结束后，用 `flutter run -d <device-id> --target lib/main.dart`
恢复普通开发入口。

需要单独生成测试 APK 时，才使用以下流程；更换测试文件即可运行另一项：

```sh
flutter build apk --debug --target-platform android-arm64 \
  --target integration_test/android_receiver_restart_test.dart
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb shell am force-stop tech.soit.flutterairplay
adb shell am start -n tech.soit.flutterairplay/.MainActivity
```

之后仍用 `--use-existing-app` 附加 driver。恢复普通入口时重新生成普通 Debug APK 并用
`adb install -r` 替换；只在需要恢复 Release 版本时构建 Release。
安装前确认 application ID 和签名一致，以保留数据。

## 测试素材与诊断

`native/player-tests/` 与平台测试复用合成素材，没有真实投屏录制：

- 音频为合成 880 Hz 双声道，ALAC 4096、AAC 1024、AAC-ELD 480/512 样本帧。
  同时构造 352 样本 ALAC 包，检查 PCM、deadline、FLUSH 和坏包恢复。
  系统 AAC decoder 可能缓冲初始包，fixture 使用连续输入。
- 时钟测试使用 440 Hz PCM，检查设备时间抖动、长中断后的重置和重新锚定。
  ALAC 接收 fixture 覆盖 RTP burst、32 位时间戳回绕、FLUSH 后新锚点与 NTP 时间戳。
- H.264/HEVC 素材为合成色块，覆盖横竖屏、4K、Main10、参数变化、格式切换和关键帧恢复。
  HEVC 参数解析测试逐一截断输入并检查空或过大的参数。
- macOS 检查 60 FPS B-frame 提交顺序、九帧 burst、reset 取消以及单帧延迟 100 ms 后恢复。
  这些回调测量的是提交到纹理适配器的时刻，不是 Flutter 栅格消费或实际屏幕扫描。
- 会话测试在同一 GOP 内暂停/恢复红到蓝的画面，不依赖新 IDR，并保持音频和时钟。
  Android 还检查更换输出 surface 后恢复画面。
- Android 默认检查系统选定 decoder，使用每批 9 帧的 60 FPS burst 输入。
  完整矩阵覆盖额外硬件、低延迟和软件 decoder，以及 1、3、9 帧批次，
  约 120 Hz 采样检查提前呈现、丢帧和间隙。
  Qualcomm 重排 fixture 覆盖 1440p30、POC type 0 与实际 B-frames。
- Windows NV12/P010 像素 fixture 覆盖颜色、stride 和畸形缓冲。
  在其他系统独立运行只证明转换和边界逻辑，不能证明 Windows MFT、WASAPI 或 DNS-SD。

重排素材生成命令（要求 FFmpeg、ffprobe 和 x264 CLI）：

```sh
python3 native/player-tests/generate_reorder_fixtures.py
```

Linux 视频素材由 `linux/tests/generate_video_fixtures.sh` 自动生成，无需日常手动调用。
Linux 原生测试还生成 `build/linux-native/linux_synthetic_demo`，它使用根 Flutter UI 和
合成纹理，不启动发现、接收或音频，也不安装进产品。已有 Debug bundle 时可运行：

```sh
LD_LIBRARY_PATH="$PWD/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ./build/linux-native/linux_synthetic_demo "$PWD/build/linux/x64/debug/bundle"
# Append portrait for the portrait fixture.
```

Android 的 `PacingTest` 另有 `--phase-sweep` 诊断选项，在 decoder 参数后传入。
它检查 120/60 Hz 消费端与 0、3、7、11、15 ms 相位。60 Hz sweep 不属于默认回归，
定时消费可能与 SurfaceTexture 异步交付竞争；失败仍需报告。
在 fixture 构建后将 `classes.dex`、`libairplay_player.so` 和 `libplayer_regression.so`
复制到设备测试目录，设置 `CLASSPATH`，通过 `app_process` 调用
`tech.soit.flutterairplay.player_regression.PacingTest` 并传入目录、decoder 和诊断参数。
它不模拟 Choreographer 或 Flutter 栅格调度。

## 打包与分发

Flutter 平台构建会自动准备最新原生产物。依赖、许可与对应源码要求见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。保留许可证资产和分发包中的运行时依赖。

| 平台 | 命令 | 输出 / 注意事项 |
| --- | --- | --- |
| macOS | `./scripts/package_macos.sh` | `build/distribution/macos/` 下的 app、ZIP、SHA256；内部调用原生及 Release 构建，并进行 ad-hoc 签名和审计 |
| Android | `flutter build apk --release --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-release.apk`；本地使用 debug signing |
| iPad 编译检查 | `flutter build ios --release --no-codesign` | 无签名设备构建，不能安装；可用 `flutter build ios --simulator --debug --no-codesign` 检查模拟器编译 |
| Windows | `flutter build windows --release` | `build/windows/x64/runner/Release/`；保留整个目录、原生 DLL 和 FFmpeg 运行时；缺少依赖时打包失败 |
| Linux | `flutter build linux --release` | `build/linux/x64/release/bundle/`；保留整个目录及 `data/`、`lib/`，系统动态依赖另行安装 |

macOS 包无需 Homebrew 运行时；Developer ID 签名与公证是额外分发步骤。
Android 授权更新使用同一 application ID/签名的 `adb install -r` 保留数据。
Windows FFmpeg 构建仅启用原生 AAC、HEVC decoder 及相关共享库，不启用 GPL/nonfree
或外部 codec，包内包含固定来源和构建配置。Linux 系统依赖许可见 [NOTICE](linux/NOTICE)。

## 资源与内部脚本

应用图标使用同一原图，各平台尺寸和裁切方式分别导出。在 macOS 上执行：

```sh
swift scripts/generate_icons.swift
```

原图来源、生成提示词、平台输出与托盘配色说明见
[应用图标资源](assets/app_icon/README.md)。资源不需要再次调用图像生成服务。
新增 UI 文案同时更新 `lib/l10n/app_en.arb` 和 `app_zh.arb`，然后执行 `flutter gen-l10n`。

下面这些脚本由构建入口调用，属于内部步骤：

| 脚本 | 调用方 / 用途 |
| --- | --- |
| `scripts/ensure_native.py` | Gradle / Xcode scheme / Windows CMake；准备原生播放器，校验构建输入与产物并复用缓存，要求 Python 3.9+ |
| `android/scripts/fetch_deps.py` | macOS、Android、iPad 原生构建；按 lock 文件获取并校验共享依赖 |
| `windows/scripts/build_ffmpeg.sh` | Windows 原生构建；构建包内 FFmpeg |
| `scripts/embed_player.sh` | macOS Xcode 构建；嵌入播放器库 |
| `scripts/audit_macos.py` | macOS 打包；检查包内依赖、签名与许可证 |
| `scripts/build_info.cmake`、`scripts/write_build_time.cmake`、`scripts/write_build_time.sh` | 宿主构建；生成构建时间 |
| `linux/tests/generate_video_fixtures.sh` | FFmpeg/Linux 视频测试；生成合成素材 |

原生产物、缓存和 Flutter 构建产物保存在 ignored 输出目录。
本地日志、截图、设备标识和单次验证报告保存在 ignored `artifacts/`。
许可证文件和 `vendor/*/UPSTREAM.md` 维护来源信息，继续独立保留。

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

命令均从仓库根目录执行。Flutter stable 版本由 `.flutter-version` 固定；
确保 PATH 中的 `flutter --version` 与该文件一致。升级时先用新 stable 跑完相关验证，
再更新 `.flutter-version` 和依赖锁文件。
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
原生产品源码、依赖和构建配置未变且产物完整时直接复用；变化或产物缺失时自动重建。
Apple Swift 宿主、native 测试和测试素材不参与产品准备指纹，CMake 负责源码的增量编译。
第三方库仅在 lock、依赖构建脚本或工具链变化时清理缓存。
原生代码变化后重新执行 `flutter run`；热重载只更新 Dart。首次构建需要联网下载固定依赖。
macOS / iPad 使用 Xcode scheme 预构建，Android 使用 Gradle `preBuild`，Windows 使用 CMake，
Linux 继续使用已有 CMake 构建。以下独立脚本保留用于原生调试和构建测试 fixture，无需在日常运行前手动执行。
当前独立原生构建脚本使用优化配置；这不要求 Flutter 应用也使用 Release。

Dart 接收控制通过 `native/include/airplay/receiver_ffi.h` 的一个 JSON 请求入口提供，
生成的 FFI 绑定只包含 ABI 版本、订阅管理和 `airplay_receiver_control`。
请求格式为 `{"method":"snapshot","arguments":{}}`；支持 `snapshot`、`save`、
`start`、`stop`、`disconnect`、`applySettings` 和 `check`。
控制操作在原生串行线程执行，结果通过 Dart port 复制发送：
`{"type":"complete","request":1,"data":{...}}`，失败时携带 `error` 字符串。
热重启替换订阅后，旧订阅尚未开始的命令及其完成消息会被丢弃。
查询和 snapshot 事件使用同一个序列化入口，不维护 Dart 专用的 C struct 映射或结果缓存。
原生宿主继续使用 `receiver.h` 的同步控制、系统生命周期及后台请求函数。
平台 channel 只处理宿主初始化及系统准备；视频帧仍直接送到纹理或 Surface。
公共设置以 `ReceiverSettings` 表示，由 `ReceiverSettingsStore` 通过 `shared_preferences` 保存，
使用独立的 `receiver.settings` key，不读取旧版平台配置。
C++ 使用明确的设置结构和状态枚举持有运行时数据，JSON 只作为控制边界的数据格式。
登录启动通过独立的 OS adapter 读取与显式修改，不再随接收器设置保存或启动回放。
macOS/Windows 使用窗口 channel；Linux 使用单个 XDG autostart desktop entry。旧的
`launchAtLogin` 接收器偏好只保留兼容字段，不作为系统状态来源或自动重新登记的依据。
`native/receiver/` 保留接收行为和串行线程，只提供复制事件的出口。
`native/ffi/` 订阅该出口并管理 Dart port、订阅及 JSON 完成消息；同步宿主接口不依赖 Dart。
`native/protocol/` 转换 UxPlay 回调、管理连接及发现记录；`native/playback/` 负责
媒体队列、时钟和调度，解码及输出放在 `native/backends/`。
Repository 先持久化期望设置，再提交 native；native 拒绝时恢复旧的持久化值。
Repository 在接收器空闲时请求应用待生效设置，C++ 在同一 worker 上判断会话并执行。
默认设备名清洗和通用画质档位由 C++ 提供；平台只提交系统名称及硬件能力。
macOS 与 iOS 共用 `native/apple/` 中的宿主和 Flutter 纹理代码。

修改 C ABI 后，从仓库根目录重新生成并提交绑定：

```sh
dart run ffigen --config tool/ffigen_receiver.yaml
```

接收状态、设置、能力、事件和日志对象使用 `json_serializable` 生成 JSON 解析。
修改这些对象的字段或 JSON 注解后，重新生成并提交 `*.g.dart`：

```sh
dart run build_runner build
```

字段默认值和枚举映射定义在对象中。Dart 控制边界使用一个 `airplay_receiver_control` JSON 请求入口，
查询和事件共享 native 快照序列化。结果直接通过 Dart port 发送 JSON，
无需取出或释放 C 结果对象。宿主仍使用其同步 C 接口。
JSON 解析用于命令结果、原生事件和持久化；adapter 兼容快照中的平铺设置格式。
CI 会检查生成文件是否与对象声明一致。

原生构建需要 PATH 中的 Dart/Flutter SDK，或显式设置 `DART_SDK_ROOT` / `FLUTTER_ROOT`。
只有 FFI 通信源码和相关测试包含 SDK 头文件。CMake 仅使用 SDK 的公开 `dart_native_api.h`，不链接 Dart VM。Android 交叉编译也读取宿主 SDK。
Dart 热重启会替换原生消息端口，保留宿主接收器；停止/销毁仍在原生完成。

日常迭代只检查受影响流程或运行针对性测试。不要每次小改都构建所有平台、执行全部回归。
发布、包内容检查和 Release 特有问题才进入[打包与分发](#打包与分发)。

## 平台环境与原生构建

### macOS

当前原生构建要求 Apple Silicon Mac、Xcode macOS SDK、CMake、Python 3 和 Perl。
Intel 构建未验证。缺少 CMake 时可通过 `brew install cmake` 安装。

```sh
./scripts/build_receiver.sh
```

脚本读取 `native/dependencies.lock.json` 校验源码，构建共享 C++ 播放器及静态 OpenSSL、
libplist，输出到 `build/macos-native/`。产品入口只构建播放器，测试入口显式启用并构建测试 target。
Xcode 负责链接与打包，系统提供 VideoToolbox、
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
共享依赖源码缓存位于 `build/native-deps/`，Android 交叉编译依赖位于 `android/.cache/`，原生输出位于 `build/android-native-arm64-<ndk-version>/`，JNI 库复制到
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

在 Linux 上安装 GTK 3、FFmpeg 6+（`libavcodec >= 60`）、OpenGL 3.2+ / OpenGL ES 3+、libepoxy、PulseAudio 兼容音频服务、
Avahi、OpenSSL 和 libplist 2.3+ 的开发包。
Debian 13 可使用：

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev libepoxy-dev \
  libpulse-dev libavahi-client-dev \
  libssl-dev libplist-dev libx11-dev libxi-dev
```

`flutter run -d linux` 会通过 CMake 一并构建原生代码，无需独立原生构建步骤。
运行时需要可用的系统 D-Bus、`avahi-daemon` 和 PulseAudio/PipeWire 输出服务。
应用不会代为启动系统服务或调整防火墙。配置和配对数据位于
`$XDG_CONFIG_HOME/flutter-airplay`，通常为 `~/.config/flutter-airplay`。

Linux 宿主自动尝试 FFmpeg CUDA/NVDEC，再尝试 VAAPI，最后回退软件解码。
驱动和系统 FFmpeg 必须支持实际视频的 codec/profile。NVIDIA 构建时若有
`ffnvcodec/dynlink_cuda.h`（`nv-codec-headers`；Ubuntu 包 `libffmpeg-nvenc-dev`），
启用 CUDA/OpenGL 互操作；运行时动态加载 `libcuda.so.1`，无需 CUDA Toolkit 或 nvcc。
Flutter 的 EGL/GLES 共享上下文及旧 GDK 上下文均受支持；跨 EGL 上下文用 GPU fence 同步。
同一 GPU 上的兼容 CUDA/OpenGL 帧直接在 GPU 复制 YUV 平面、用 shader 转成 RGBA，
再交给 Flutter `FlTextureGL`，不下载到 CPU。互操作不可用时下载 YUV 并在 GPU 转色；
不支持的颜色空间/像素格式回退 CPU RGBA；GLES 的 10-bit shader 需要 `GL_EXT_texture_norm16`。日志 `Linux video decoder active` 和
`Linux GL texture stats` 的 `output_path` 区分实际路径，GPU 取帧不代表屏幕呈现。

GPU 验证复用 native 入口，基础 GPU 像素检查使用 Xvfb；Flutter 纹理检查需先构建应用：

```sh
./scripts/test_native.sh linux gpu
# 已登录的 NVIDIA 桌面上，额外验证实际 NVDEC、CUDA/OpenGL、下载回退及合成 4K60：
./scripts/test_native.sh linux gpu -DAIRPLAY_LINUX_GPU_HARDWARE_TESTS=ON
# 结束设备矩阵后恢复默认，不让后续 all 套件依赖 NVIDIA 桌面：
./scripts/test_native.sh linux gpu -DAIRPLAY_LINUX_GPU_HARDWARE_TESTS=OFF
```

这些用例覆盖 H.264/HEVC、Main10、旋转、重置、颜色范围/矩阵、GL 状态恢复和帧引用清理。
合成 4K60 用例不证明真实 iPhone 投屏或显示器呈现帧率；接入后需用实际投屏日志检查
队列等待、迟到丢帧和纹理覆盖率。Intel/AMD VAAPI 的设备验证需在相应 GPU 上执行。

## 按改动选择验证

代码位置、编译 target 与验证入口按职责对应：

| 要改的内容 | 代码位置 / target | 影响范围与最小验证 |
| --- | --- | --- |
| 公共设置或运行状态 | `lib/receiver/receiver_settings.dart`、`receiver_state.dart`、`native/include/airplay/receiver.h` | 五个平台；更新 codec 和生成绑定，跑 `flutter test test/receiver/` 与 native receiver / FFI 用例 |
| 接收控制、设置生效或生命周期 | `native/receiver/` / `airplay_receiver_control` | 五个平台；`./scripts/test_native.sh receiver`，再跑宿主及 FFI 用例 |
| UxPlay 回调、连接或 TXT | `native/protocol/` / `airplay_protocol`，`vendor/UxPlay/` / `receiver_core` | 五个平台；协议、会话和 RTP 用例，加受影响宿主构建 |
| 媒体队列、时钟或调度 | `native/playback/` / `airplay_player` | 五个平台；对应 player 用例，增加后端恢复检查 |
| codec、音频设备或帧输出 | `native/backends/<backend>/` | 使用该后端的平台；对应 codec / 输出测试与平台构建 |
| 窗口或系统操作 | `lib/platform/window_controller.dart`、平台 runner | 对应平台；widget 输入测试和窗口 / 宿主用例 |
| 页面、主题或焦点 | `lib/ui/`、`lib/app/` | 共用页面的平台；`flutter test test/ui/` 和受影响布局 / 输入流程 |
| 依赖、源码选择或准备缓存 | `native/CMakeLists.txt`、`native/cmake/`、构建脚本 | 对应 native target；`./scripts/test_native.sh build`，确认变更重建、无变更复用 |

CMake 从实际产品 target 导出 `build/native-preparation/<platform>-sources.txt`，
外层准备脚本据此检查源码目录，不根据文件名前缀猜测参与构建的平台。源码新增或改名
由所属目录的指纹检测；CMake 配置与编译负责实际选择和增量。首次没有清单时保守重建。
依赖缓存单独按 lock、依赖构建脚本和工具链失效，修改产品源码无需清理依赖。

公共控制测试不需要 Dart SDK 或媒体库，可通过 `AIRPLAY_CONTROL_ONLY=ON` 单独配置。
产品默认 `AIRPLAY_BUILD_FFI=ON`；关闭时只有 Dart transport 被排除，宿主同步控制仍保留。
CTest labels 使用 `receiver`、`ffi`、`protocol`、`playback` 和 `backend` 标识用例职责。

native 调试配置与 Flutter Debug 独立。以 macOS 为例，保留默认优化产物，
另建带符号且不优化的目录：

```sh
cmake -S native -B build/native-debug/macos -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DUXPLAY_SOURCE="$PWD/vendor/UxPlay" -DPLIST_SOURCE="$PWD/build/native-deps/libplist" \
  -DCRYPTO_PREFIX="$PWD/build/macos-crypto" -DAIRPLAY_BUILD_TESTS=ON
cmake --build build/native-debug/macos --parallel 8
ctest --test-dir build/native-debug/macos --output-on-failure
```

Android、iPad 和 Linux 也可在对应脚本的 CMake 参数基础上选择 `Debug` 或
`RelWithDebInfo`，并用独立 `-B build/native-debug/<target>` 目录。Windows 使用
独立构建目录和 `--config Debug`；FFmpeg 的优化依赖不因此重新构建。
这些目录用于 native 调试和测试；平台应用的自动打包仍读取其默认产品目录。


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
Dart 用例按 `test/receiver/`、`test/ui/` 组织，fixture 位于对应测试目录。
共享 native 用例位于 `native/tests/`；真实平台宿主、设备和窗口用例保留在各平台。
原生自动构建入口的缓存、源码/依赖变化、产物缺失与失败恢复及依赖方向检查使用 `./scripts/test_native.sh build`。

### GitHub Actions

`CI` 在 PR 和推送到 `main` 时运行，也可在 Actions 页面手动启动全部平台任务。
各平台使用 `.flutter-version` 固定的 Flutter stable，依赖安装校验 `pubspec.lock`，应用编译统一使用 Debug。
每周一的 `Verify new Flutter stable` 任务用最新 stable 检查 Dart 分析、测试、绑定生成及构建规则，
不会自动修改固定版本。
独立原生脚本仍使用自身的优化配置。

| 任务 | 覆盖 |
| --- | --- |
| Format, analyze and Dart tests | workflow 的 actionlint、原生构建入口回归、Dart format 检查、FFI 绑定重新生成差异检查、`flutter analyze --fatal-infos`、完整 `flutter test` |
| macOS | 原生构建、Debug 应用编译、player/host/texture/RTP 回归 |
| Linux | Debug 应用编译、完整 native suite、Xvfb 中的 GTK/托盘及真实标题拖动、独立 ALAC decoder |
| Windows | 原生及 Debug 应用编译、像素、兼容层、HTTP 生命周期、音频恢复、平台/GPU/FFmpeg 视频及 Flutter 纹理生命周期回归 |
| Android | arm64 JNI 与 Debug APK 编译、host 协议测试、Kotlin 单元测试 |
| iPad | 设备/模拟器原生归档、模拟器 Debug 应用、iPad 模拟器 XCTest |

轻量检查每次运行。共享代码、依赖、资源或 workflow 变化会触发全部平台；
平台专用目录变化触发对应平台任务；其他平台也引用的 Android C++ 按共享代码处理。
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
跳过时输出明确的 `SKIP` 原因；其他视频、暂停恢复、GTK 宿主生命周期测试照常运行。
本地及 self-hosted runner 保留这两项检查。

### Dart

```sh
flutter analyze
flutter test test/receiver/receiver_repository_test.dart
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
| Windows 视频 / 全部 | `bash scripts/test_native.sh windows video` / `windows all` | 显式检查平台、D3D11 纹理转换/硬解及 FFmpeg 视频 decoder，或全部原生 fixture；无可用显卡时 GPU 转换明确跳过 |
| Windows 纹理宿主 | `bash scripts/test_native.sh windows texture` | 先用 `flutter build windows --debug` 准备宿主，再执行 `cmake --build build/windows/x64 --config Debug --target windows_texture_test`；检查 Flutter GPU 纹理描述的导入、释放、旋转及重连 |
| Linux 基础 | `./scripts/test_native.sh linux` | Linux 开发依赖；时钟、PCM/音频、H.264 恢复、会话与 loopback；只构建相关 fixture |
| Linux 视频 / 宿主 / 全部 | `./scripts/test_native.sh linux video` / `linux host` / `linux all` | 视频矩阵需要 ffmpeg/ffprobe 和 Python 3；宿主需要 Flutter engine；all 包括可用的窗口宿主测试 |

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

桌面窗口的全屏、最大化、最小化、拖动、尺寸、比例、置顶与显示/隐藏统一由
`WindowController` 调用 `nativeapi`。`DesktopPresentation` 持有托盘、菜单、窗口事件订阅和
会话自动显示/隐藏的计时器，使用共享接收器状态和 Flutter 本地化。三种桌面宿主均启用
UI / 平台线程合并，使 FFI 调用和同步事件回调在平台线程执行。
窗口调用避开 Flutter 当前帧，防止 AppKit 同步调整尺寸时嵌套帧回调。
普通窗口命令在非合并引擎上可通过 `runOnPlatformThread` 切换线程；托盘事件订阅要求合并线程。
最大化/还原直接订阅 `WindowManager.addListener`。宿主不重复发送普通尺寸和最大化事件，
只补充当前插件缺少的全屏完成通知，另保留关闭请求拦截、可靠退出/接收器清理和防休眠。
macOS 还保留 Dock 激活策略与系统菜单，避免 `nativeapi 0.4` 的 Application 初始化替换 Flutter AppDelegate；
编辑菜单继续使用系统 responder chain。
Linux 托盘可用性按 `TrayManager.isSupported()` 判断，不再依赖 Ayatana AppIndicator。

真实桌面回归：`flutter test -d macos integration_test/desktop_window_test.dart`。
同一用例也可选择 `windows` 或 `linux`；验证标题栏不参与导航、反复进入/退出全屏、
窗口隐藏后仍通过 runner 提供的固定原生句柄恢复（不依赖活动窗口查询）、
视频比例/旋转/原始像素尺寸、置顶、播放在全屏中结束、关闭到托盘、连接后显示和延迟隐藏。
Swift / GTK 原生窗口 fixture 只检查剩余的关闭与状态桥接。
共享标题栏位于 `MaterialApp.builder` 的导航外层；页面和弹层只更新下面的内容。


| 目标 | 命令 | 前置条件 |
| --- | --- | --- |
| macOS | `./scripts/test_native.sh macos window` | `flutter run -d macos` 生成的 Debug 产物，以及已登录的 macOS GUI 会话 |
| Linux GTK 窗口宿主 | `./scripts/test_native.sh linux all` | 已有 Flutter engine 库，额外安装 `xvfb`、`dbus-x11`；运行在隔离显示和 session bus 中 |
| Linux 实际标题拖动 | `./scripts/test_native.sh linux window` | 已有 Debug bundle，额外安装 `xvfb`、`dbus-x11`、`openbox`、`xdotool`；真实鼠标操作检查拖动后坐标及关闭 |

Linux 拖动测试可接收其他 bundle 路径：`./scripts/test_native.sh linux window <bundle-path>`。
隔离环境的 GTK 窗口测试不能替代真实桌面环境兼容性验证；托盘行为由桌面 Flutter 集成测试验证。

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

运行时诊断在各平台进入同一份接收器日志，可从应用日志页导出。接收、提交和调度统计
由公共 C++ 播放层输出；解码后端保留自己的队列、耗时和恢复信息。
公共播放层在已消费的视频输入超过 3 秒仍无新输出时，于约 5 秒的统计周期记录
`Video output stalled`，包含解码器、编码格式、输入/输出距今时长及音频状态。
成功输出后停止输入，以及发送端主动暂停时不报警。失败输入尚未产生输出时，即使后续
输入停止也保留告警。Apple 后端额外记录 VideoToolbox 回调错误码、
flags、空图像和丢帧计数；每个统计周期最多输出一条详细回调失败日志，避免坏帧刷屏。
macOS 与 iPad 共用 VideoToolbox、AudioUnit 和 Apple 纹理统计。
Windows 的 GPU/像素纹理与 Linux GL/像素纹理共用 `TextureStats`。
公共接收器约每 5 秒采集宿主纹理统计，停止前采集剩余数据；收到过帧后即使画面冻结，
仍记录零计数区间及 `last_receive_age_ms`、`last_acquire_age_ms`，未取过新帧时后者为 -1。
`received` 是适配器收到的帧数，`acquired_new` 是 Flutter 取走的新帧数，
`overwritten_before_acquire` 是被后续帧替换而未取走的帧数。
通知延迟、帧年龄和取帧间隔用于定位栅格消费之前的阻塞；取帧不代表屏幕实际显示。
Linux GL 额外记录 `notification_requests`、`notification_coalesced`、`notifications` 和
`populate_calls`，对照生产请求、主线程合并通知和 Flutter 实际取纹理次数。
`mark_to_populate` 从最早尚未消费的纹理通知计时，`populate_gap` 记录回调间隔，
`populate_cost` 记录整个回调耗时（包括缓存读取或失败），`gpu_output` 记录转换路径耗时。
这些耗时是 CPU 侧单调时钟测量，不代表异步 GPU 工作完成或屏幕呈现。
GL 的 `acquired_new` 在选择帧时计数，`replaced_during_populate` 单独记录转换期间被新帧替换；
不会因转换期间生产者更新而漏记已选帧。计数和耗时样本每个报告区间重置。
Linux GPU 宿主在取纹理完成后通过主线程请求下一次纹理重绘；`repaint_requests` 区分
这类请求和生产者通知。使用一帧抖动缓冲（最多保留三帧，满时丢弃最旧帧），
60 FPS 下增加约一帧延迟，减少两个时钟交错时的重复／跳帧。
`queued_frames` 显示尚未取走的帧，`frame_age` 使用实际选中帧的接收时刻；
队列溢出和尺寸切换丢弃计入 `overwritten_before_acquire`。
输入停止后取完最后的缓冲帧并停止后续请求；清空和退出时取消请求并释放帧。
CUDA/OpenGL 平面按 GL 存储和 CUDA 设备上下文缓存注册，尺寸、格式或设备改变时注销重建，
保留设备引用直到注销完成；同步和不兼容时的 CPU 下载回退保持有效。
Android 使用原生 Surface，记录 `released_to_surface`、提交失败和最后输入、解码、
提交距今时长，不套用 Flutter 纹理取帧指标。Surface 提交也不代表实际屏幕呈现。

`native/tests/playback/` 与平台测试复用合成素材，没有真实投屏录制：

- 音频为合成 880 Hz 双声道，ALAC 4096、AAC 1024、AAC-ELD 480/512 样本帧。
  同时构造 352 样本 ALAC 包，检查 PCM、deadline、FLUSH 和坏包恢复。
  系统 AAC decoder 可能缓冲初始包，fixture 使用连续输入。
- 时钟测试使用 440 Hz PCM，检查设备时间抖动、长中断后的重置和重新锚定。
  ALAC 接收 fixture 覆盖 RTP burst、32 位时间戳回绕、FLUSH 后新锚点与 NTP 时间戳。
- H.264/HEVC 素材为合成色块，覆盖横竖屏、4K、Main10、参数变化、格式切换和关键帧恢复。
  HEVC 参数解析测试逐一截断输入并检查空或过大的参数。
- 共享视频调度 fixture 检查未来帧不阻塞解码、输入背压、B 帧按 PTS 排序、
  过期/乱序输出丢弃、会话取消和帧资源归还；软件转换检查保留帧不会被下一帧覆盖。
  各端的 `Video scheduler` 日志统一记录队列深度、提交间隔、迟到和丢帧原因。
- macOS 检查 60 FPS B-frame 提交顺序、九帧 burst、reset 取消以及单帧延迟 100 ms 后恢复。
  这些回调测量的是提交到纹理适配器的时刻，不是 Flutter 栅格消费或实际屏幕扫描。
- 会话测试在同一 GOP 内暂停/恢复红到蓝的画面，不依赖新 IDR，并保持音频和时钟。
  Android 还检查更换输出 surface 后恢复画面。
- macOS HEVC 中断测试先验证 6 秒接收空档能保留参考帧，再送入过期 IDR 和后续 5 帧，
  检查过期帧不显示，后续帧无需等待新 IDR 就能恢复，且音频 PCM 继续正常。
  另外模拟 IDR 真正缺失，检查冻结诊断和新 IDR 到达后的恢复。单独运行：
  `./scripts/test_native.sh macos player -R '^video_interruption$' --verbose`。
  合成素材生成器为 `native/tests/fixtures/generate_interruption_fixtures.py`，需要 FFmpeg/libx265；
  测试直接使用已提交的 fixture，不需要现场生成。
- Android 默认检查系统选定 decoder，使用每批 9 帧的 60 FPS burst 输入。
  完整矩阵覆盖额外硬件、低延迟和软件 decoder，以及 1、3、9 帧批次，
  约 120 Hz 采样检查提前呈现、丢帧和间隙。
  Qualcomm 重排 fixture 覆盖 1440p30、POC type 0 与实际 B-frames。
- Windows NV12/P010 像素 fixture 覆盖颜色、stride 和畸形缓冲。
  在其他系统独立运行只证明转换和边界逻辑，不能证明 Windows MFT、WASAPI 或 DNS-SD。

重排素材生成命令（要求 FFmpeg、ffprobe 和 x264 CLI）：

```sh
python3 native/tests/fixtures/generate_reorder_fixtures.py
```

Linux 视频素材由 `native/tests/fixtures/generate_video_fixtures.sh` 自动生成，无需日常手动调用。
Linux 原生测试还生成 `build/linux-native/linux_synthetic_demo`，它使用根 Flutter UI 和
合成纹理，不启动发现、接收或音频，也不安装进产品。已有 Debug bundle 时可运行：

```sh
LD_LIBRARY_PATH="$PWD/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ./build/linux-native/linux_synthetic_demo "$PWD/build/linux/x64/debug/bundle"
# Append portrait for the portrait fixture.
```

真实 Flutter 引擎的 4K60 取纹理诊断使用同一合成演示和根 UI，测试进程隔离设置、
不启动接收服务或音频。先准备 Profile bundle；在可见、未遮挡的 60 Hz（或更高）
NVIDIA 桌面运行显式矩阵，不用 Xvfb 替代真实刷新节奏：

```sh
flutter build linux --profile
./scripts/test_native.sh linux gpu --filter '^linux_gpu_flutter_pacing$' --verbose \
  -DAIRPLAY_LINUX_GPU_PACING_TESTS=ON
# 完成后关闭持久的本地矩阵选项：
./scripts/test_native.sh linux gpu -DAIRPLAY_LINUX_GPU_PACING_TESTS=OFF \
  -DAIRPLAY_LINUX_GPU_HARDWARE_TESTS=OFF
```

测试持续约 20 秒，前 5 秒预热，随后记录三段 5 秒统计；要求至少收到 870 帧，
实际启用 NVDEC/CUDA 互操作、无 GPU 错误，且取走至少 90% 的帧。
`BENCHMARK RESULT` 输出取帧比例和频率；失败可用于复现已知的 Linux 帧调度问题，
不要把它作为解码器吞吐失败或屏幕实际显示帧率。该性能矩阵默认关闭，
优化前在当前桌面上已复现稳定输入 60 FPS、纹理消费约 50 FPS 的失败；
不同启动相位有差异，应对比多次运行，单次通过不证明持续满 60 FPS。
其他 bundle 路径可通过 `-DAIRPLAY_FLUTTER_PROFILE_BUNDLE=/absolute/path` 指定。
Linux 原生入口的 `--filter` 只筛选指定套件内需要复跑的 CTest 用例。


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
| macOS | `./scripts/package_macos.sh` | `build/distribution/macos/` 下的 app、带版本号的 arm64 DMG、SHA256；自动 Release 构建、ad-hoc 签名、挂载审计和原生加载检查 |
| Android | `flutter build apk --release --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-release.apk`；正式签名由 Gradle 从环境变量读取；CI 按版本命名 |
| iPad 编译检查 | `flutter build ios --release --no-codesign` | 无签名设备构建，不能安装；可用 `flutter build ios --simulator --debug --no-codesign` 检查模拟器编译 |
| Windows | `powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/package_windows.ps1` | `build/distribution/windows/Flutter-AirPlay-<version>-windows-x64-setup.exe` 和 `SHA256SUMS`；自动构建 Release、校验并打包完整运行时 |
| Linux | `python3 scripts/package_linux.py` | `build/distribution/linux/` 下的 `.deb`、`-bundle.tar.gz` 和校验和；完整 Release bundle，系统动态依赖另行安装 |

macOS DMG 面向 Apple Silicon（arm64）、macOS 12+，不是 universal / Intel 包；
无需 Homebrew 运行时。打开 DMG 后将 `Flutter AirPlay.app` 拖到 `Applications`。
Ad-hoc 签名只封存代码完整性，不认证开发者身份；不需要 Apple 开发者账户、付费证书、
签名密钥或额外 GitHub Secrets，也没有 Developer ID 签名或 Apple 公证。
从网络下载后 macOS 仍可能阻止打开；不要关闭 Gatekeeper / SIP 或清除隔离属性来绕过检查。
面向免提示的公开分发需另行配置 Developer ID 签名与公证。
打包先从副本移除预编译框架残留的外部 rpath（如 `/usr/local/lib`），再逐层签名并检查 arm64、实际 rpath 依赖、许可证、Bonjour 声明和 Release entitlements；
生成只读压缩 DMG 后重新挂载审计，并加载包内 dylib 检查 FFI ABI，不启动接收服务。
这不等于已验证 GUI 启动、Gatekeeper 下载体验或真实 iPhone 投屏。

Windows 安装包要求 Inno Setup 6.6+，可用 `winget install --id JRSoftware.InnoSetup -e -s winget`
安装，或为脚本传入 `-InnoCompiler 'C:\path\ISCC.exe'`。`-SkipBuild` 仅复用已生成、版本号与
`pubspec.yaml` 一致的 Release bundle；原生代码改动后应使用默认构建流程。
编译器也可通过 `AIRPLAY_ISCC` 指定；脚本优先使用该路径和
`windows/.cache/tools/inno-6.7.3/ISCC.exe` 中的本地编译器，再检测系统安装和 PATH。
安装向导使用 Windows 11 风格，随系统切换深浅色，支持英文／简体中文、许可确认、安装位置、
可选桌面快捷方式、进度和完成后启动。默认安装到当前用户的
`%LOCALAPPDATA%\Programs\Flutter AirPlay`，无需管理员权限；升级使用固定 AppId，
卸载保留用户配置与配对数据，仅清理指向本安装目录的登录启动项。
VC++ x64 CRT 从本机 Visual Studio 2022 可再分发目录复制到应用目录，安装时无需下载依赖。
不自动修改防火墙；首次接收时按系统提示允许本地网络访问。Windows N 仍需 Media Feature Pack。
Windows CI 在通过 Debug／原生回归后使用固定的 Inno Setup 6.7.3 编译并上传
`windows-x64-setup` artifact；打包产物目前未签名，正式分发的 Authenticode 签名另行配置。
`bash scripts/test_native.sh windows installer build/distribution/windows/Flutter-AirPlay-<version>-windows-x64-setup.exe`
验证英文静默安装、中文覆盖升级、安装文件、Release 进程启动和卸载；先退出应用，
且当前用户不能已有正式安装。用例安装到 `artifacts/windows-installer-smoke/app`，
结束时卸载，日志保存在同一个 ignored 目录。它验证安装生命周期，不替代向导页面的人工检查。
Android 授权更新使用同一 application ID/签名的 `adb install -r` 保留数据。
Windows FFmpeg 构建仅启用原生 AAC、HEVC decoder、D3D11 HEVC 硬解及相关共享库，不启用 GPL/nonfree
或外部 codec，包内包含固定来源和构建配置。Linux 系统依赖许可见 [NOTICE](linux/NOTICE)。

### GitHub tag 自动发布

手动运行 `Release assets` 时可勾选 `macos_only`，只构建和验证 macOS DMG，
不读取 Android 签名密钥、不发布 release；下载运行中的 `release-macos` artifact。
默认手动运行仍构建所有平台。

`.github/workflows/release.yml` 在推送 `vMAJOR.MINOR.PATCH` tag 时构建并上传：

- `Flutter-AirPlay-<version>-linux-x64.deb`
- `Flutter-AirPlay-<version>-linux-x64-bundle.tar.gz`
- `Flutter-AirPlay-<version>-windows-x64-setup.exe`
- `Flutter-AirPlay-<version>-macos-arm64.dmg`（ad-hoc 签名，无公证）
- `Flutter-AirPlay-<version>-android-arm64.apk`（已配置正式签名时）
- 所有应用产物的 `SHA256SUMS`

先在 `pubspec.yaml` 更新 `version: MAJOR.MINOR.PATCH+BUILD` 并提交，再在这个提交上创建
对应 tag（例如 `version: 0.1.2+3` 对应 `v0.1.2`）。tag 与 pubspec 不一致、预发布后缀、
非法版本号会在构建前失败。`BUILD` 是 Android versionCode 和 Windows 文件版本的第四段，
必须为 1..65535；更新时递增，不能仅改 tag 给旧二进制换版本。SDK 使用 `.flutter-version`。
GitHub Actions 的手动运行只构建和保留 artifacts，永远不创建或发布 Release。
Release 工作流仅允许手动运行和推送版本 tag 触发，不在 PR 创建或更新时运行。

Linux 和 Windows 都成功，且 Android 成功构建或明确因未配置签名跳过后，才开始创建 draft
Release。上传并验证完整资产集合后才转为公开；任一步失败会保留 draft。
同一 tag 的失败运行可重试，只覆盖对应提交的 draft 中已知资产；已公开 Release 不覆盖，
修改后发布新版本。工作流不会创建 tag；不要把 tag 的手动创建作为构建测试。
第三方 Actions 固定到 commit SHA，构建 job 只有 contents:read，只有最终上传 job 获得
contents:write；没有 pull_request_target 或来自 PR 的签名任务。

Linux 发布环境是 Ubuntu 24.04 x64，需要 `dpkg-dev`、`fakeroot`、`desktop-file-utils`、
`default-jdk-headless` 及前文 Linux 编译依赖，并设置 `JAVA_HOME=/usr/lib/jvm/default-java`。打包器扫描所有 ELF，通过 `dpkg-shlibdeps` 计算目标系统 Depends，
另加 `avahi-daemon`。当前 JNI native asset 还需要 `default-jre-headless` 提供 `libjvm.so`，
打包器检查稳定的 Java runtime 路径，避免带入 CI runner 私有 JDK 路径。不能在别的发行版
上生成包后声称与 Ubuntu 24.04 兼容。
`.deb` 用 `sudo apt install ./Flutter-AirPlay-<version>-linux-x64.deb` 安装，应用菜单或
`flutter-airplay` 启动。bundle 解压后保持整个目录，以 `./flutter_airplay` 运行；其
`README.txt` 列出必须由系统提供的依赖，它不是静态链接的跨发行版 AppImage。
包中包含图标、desktop 文件、完整 Flutter/native libraries、LICENSE 和第三方声明。
`--skip-build` 仅打包已构建且版本一致的 Release bundle。

### Android 正式签名配置

工作流使用 `android-release` GitHub Environment。仓库管理员应在其中配置以下四个
Environment secrets，并设置所需审批和仅允许 release tags 的部署限制：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 已有、长期保管的正式签名 keystore 的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 固定签名 key alias |
| `ANDROID_KEY_PASSWORD` | 该 key 的密码 |

四项全部缺失时，Android job 成功但明确跳过 APK，job summary 和 Release 说明都标注原因，
桌面包仍可发布。只配置部分项、无效 keystore、错误密码或构建失败均使任务失败。
配置签名后再手动构建验证；已发布的同名
Release 不会补传，签名 APK 随下一版发布。

CI 在 GitHub 托管的一次性 Ubuntu runner 的 `RUNNER_TEMP` 以 `0600` 权限解码已有
keystore，然后直接执行 `flutter build apk --release --target-platform android-arm64`。
Gradle 从 `AIRPLAY_ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、
`ANDROID_KEY_PASSWORD` 环境变量读取签名配置；原生依赖仍由 Gradle 的 `preBuild` hook 自动准备，
不需要额外的 Android 构建包装脚本。CI 将构建出的 APK 按版本重命名上传。

keystore 不进入仓库、工作区、缓存或 artifacts，不输出密码或 Base64 密钥；不单独增加清理
步骤，由托管的一次性 runner 生命周期销毁临时文件。不要将签名 job 改为持久化 self-hosted
runner 而不重新评估密钥留存。Gradle daemon/configuration-cache 在签名构建时禁用，签名
job 不缓存 Gradle 目录。

本地同样直接使用 Flutter 命令。需要正式签名时设置上述四个 Gradle 环境变量，路径指向已有
keystore；没有显式配置时 Release 不再使用 debug key，未签名结果不能直接安装。
日常开发继续使用 `flutter run` / `flutter build apk --debug`。

已安装应用要原地升级，必须保持 `tech.soit.flutterairplay` application ID、同一正式签名 key，
并递增 versionCode。GitHub Secrets 是 CI 传递方式，不是唯一备份；在独立安全位置保存原始
keystore 和恢复信息，限制能编辑 release workflow/tag 的人员。不要每次 CI 生成新 key，
也不要将密码或 Base64 密钥粘贴到日志、issue 或聊天。已安装的 debug 签名版本不能用正式签名
直接覆盖；切换前需要用户自行安排数据保留/重新安装。

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
| `scripts/fetch_native_deps.py` | macOS、Android、iPad 原生构建；按 lock 文件获取并校验共享依赖 |
| `windows/scripts/build_ffmpeg.sh` | Windows 原生构建；构建包内 FFmpeg |
| `scripts/embed_player.sh` | macOS Xcode 构建；嵌入播放器库 |
| `scripts/audit_macos.py` | macOS 打包；检查包内依赖、签名与许可证 |
| `scripts/build_info.cmake`、`scripts/write_build_time.cmake`、`scripts/write_build_time.sh` | 宿主构建；生成构建时间 |
| `native/tests/fixtures/generate_video_fixtures.sh` | FFmpeg/Linux 视频测试；生成合成素材 |

原生产物、缓存和 Flutter 构建产物保存在 ignored 输出目录。
本地日志、截图、设备标识和单次验证报告保存在 ignored `artifacts/`。
许可证文件和 `vendor/*/UPSTREAM.md` 维护来源信息，继续独立保留。

### 登录启动验证与依赖选择

`flutter test test/platform/launch_at_login_test.dart test/ui/launch_at_login_tile_test.dart`
使用临时目录和 fake，不修改真实登录项。完整 `flutter test` 覆盖原有接收器和界面。
真实打包验收还需分别在 macOS、Windows、Linux 登录会话中验证开关、退出/重登、
系统外部禁用、路径带空格、移动安装目录和权限拒绝；Linux 云端不替代 Mac/Windows 验收。
macOS 应使用固定位置的正常签名应用包；沙盒应用仍受系统登录项批准控制。
Windows 当前 Inno Setup/便携分发继续使用 FlutterAirPlay Run value，与卸载清理保持一致；
未来改成 MSIX 时需采用该分发方式的 StartupTask，不应照搬 Run value。
Linux 不应从临时构建目录开启自启；AppImage 使用 APPIMAGE 而非临时挂载内的 executable。

评估了 [launch_at_startup 0.5.1](https://pub.dev/packages/launch_at_startup)：
Linux 实现固定写入 ~/.config、只检查文件存在且不转义 Exec；macOS 仍需额外原生 glue。
为避免覆盖本项目已实现的 SMAppService，以及修补大部分 plugin Linux 行为，本次不新增依赖。
[auto_start_flutter](https://pub.dev/packages/auto_start_flutter) 的背景任务/移动权限范围远大于此功能；
autostart_settings 和 flutter_autostart 则主要针对 Android 权限，不适合这个桌面开关。
Linux 文件遵循 [XDG Autostart](https://specifications.freedesktop.org/autostart/latest/)
和 [Desktop Entry Exec 转义](https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html)。

项目现有 nativeapi 0.4.0 也暴露 LaunchAtLogin API，但其 Linux IsEnabled 仅检查文件存在，
Exec 转义未完整处理 Desktop Entry 两层规则，故本次未直接使用该 API。
Linux 启动路径含 `%`、`=` 或控制字符时明确拒绝登记（GIO 对含 `%` 的 executable 解析有限制），
请移动到常规固定安装路径后重试；不使用 shell 或 env 命令包装应用。

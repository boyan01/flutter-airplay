# 开发指南

命令从仓库根目录执行，使用 PATH 中的 Flutter stable。
产品使用见 [README_ZH.md](README_ZH.md)，代码约定见 [AGENTS.md](AGENTS.md)。

## 运行

```sh
flutter pub get
flutter devices
```

安装对应平台的工具链后运行：

| 平台 | 命令 |
| --- | --- |
| macOS | `flutter run -d macos` |
| Android 手机 / TV | `flutter run -d <device-id>` |
| iPad / 模拟器 | `flutter run -d <device-id>` |
| Windows | `flutter run -d windows` |
| Linux | `flutter run -d linux` |

设备 ID 来自 `flutter devices`。Flutter 构建会自动准备原生依赖，首次需要联网，后续增量构建。
Dart 改动使用热重载；原生改动后重新执行 `flutter run`。

## 环境

### macOS

Apple Silicon Mac、Xcode、CMake、Python 3 和 Perl。可用 `brew install cmake` 安装 CMake。

### Android

在 macOS 或 Linux x86_64 上开发。需要 Android SDK、JDK 17+、Python 3、Perl 和 Make，
运行目标为 Android 8.0+ 的 arm64 设备。NDK 版本由 `android/gradle.properties` 管理：

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager "ndk;$(sed -n 's/^airplay\.ndkVersion=//p' android/gradle.properties)" 'cmake;3.22.1'
```

Linux 的 SDK 通常位于 `$HOME/Android/Sdk`，按本机路径设置 `ANDROID_HOME`。

### iPad

Apple Silicon Mac、Xcode、CMake、Python 3 和 Perl。支持 iPadOS 15+ 和 arm64 模拟器。
真机运行前，在 `ios/Runner.xcworkspace` 中设置签名团队。

### Windows

Windows x64、Visual Studio 2022（C++ 桌面开发、Windows SDK、Clang tools）、
CMake、Git Bash、Python 3.10+ 和 Perl。工具应在 PATH 中可用。
FFmpeg 构建使用 MSYS2/Cygwin GNU Make，缺失时脚本下载锁定版本。
自定义工具路径使用 `AIRPLAY_BASH` 和 `AIRPLAY_MAKE`。

### Linux

需要 GTK 3、FFmpeg 6+、OpenGL 3.2+ / OpenGL ES 3+、Avahi、PulseAudio/PipeWire、
OpenSSL 和 libplist 2.3+。Ubuntu 24.04 可安装：

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev libepoxy-dev \
  libpulse-dev libavahi-client-dev libssl-dev libplist-dev libx11-dev libxi-dev \
  default-jdk-headless ffmpeg
export JAVA_HOME=/usr/lib/jvm/default-java
```

运行时保持 `avahi-daemon`、session D-Bus 和音频服务可用。
NVIDIA CUDA/OpenGL 互操作另需 `nv-codec-headers`（Ubuntu 包 `libffmpeg-nvenc-dev`）。

### 单独构建原生代码

原生调试或准备测试产物时使用：

| 平台 | 命令 | 输出 |
| --- | --- | --- |
| macOS | `./scripts/build_receiver.sh` | `build/macos-native/` |
| Android | `./android/scripts/build_native.sh` | `android/app/src/main/jniLibs/arm64-v8a/` |
| iPad | `./ios/scripts/build_native.sh` | `build/ios-native/AirplayPlayer.xcframework` |
| Windows | `powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build_native.ps1` | `build/windows-native/` |
| Linux | `flutter build linux --debug` | `build/linux/x64/debug/bundle/` |

脚本使用优化配置，与 Flutter 的 Debug 模式独立。
FFI 编译从 Flutter/Dart SDK 读取头文件；自定义 SDK 路径可设置 `DART_SDK_ROOT` 或 `FLUTTER_ROOT`。

## 生成代码与资源

修改源文件后，生成文件一同提交：

| 改动 | 命令 |
| --- | --- |
| C ABI：`native/include/airplay/receiver_ffi.h` | `dart run ffigen --config tool/ffigen_receiver.yaml` |
| JSON 模型字段或注解 | `dart run build_runner build` |
| `lib/l10n/*.arb` | `flutter gen-l10n` |
| 应用图标（macOS） | `swift scripts/generate_icons.swift` |

FFI 生成需要 libclang。图标来源和导出说明见 [assets/app_icon/README.md](assets/app_icon/README.md)。

## 验证

按改动选择测试，完整 Dart 测试和当前平台基础原生测试的入口为：

```sh
flutter analyze
flutter test
./scripts/test_native.sh
```

| 改动 | 相关检查 |
| --- | --- |
| 文档 | `git diff --check`、链接和命令路径 |
| Dart 接收逻辑 | `flutter test test/receiver/` |
| UI / 输入 | `flutter test test/ui/`，运行应用检查窗口尺寸、触摸、键盘和 TV 焦点 |
| 公共控制 / FFI | `./scripts/test_native.sh receiver` 和平台原生套件中的 FFI 用例 |
| 协议 / 播放 | 对应平台的 RTP、player 或 video 套件 |
| 构建 / 依赖 / 打包脚本 | `./scripts/test_native.sh build` 和对应平台构建 |

### 原生测试

`./scripts/test_native.sh --help` 列出套件和筛选参数。
默认运行当前平台的基础套件，`all` 扩展到宿主、视频和窗口测试。

| 平台 / 范围 | 入口 | 准备 |
| --- | --- | --- |
| macOS 播放 / 宿主 | `./scripts/test_native.sh macos all` | 原生库、Debug 应用和已登录的 GUI 会话；仅检查播放使用 `macos player` |
| RTP | `./scripts/test_native.sh macos rtp` 或 `./scripts/test_native.sh android rtp` | 对应平台的原生测试环境 |
| Android host | `./scripts/test_native.sh android host` | CMake、系统 OpenSSL 开发库；macOS 可设置 `HOST_CRYPTO_PREFIX` |
| Android 播放 | `./scripts/test_native.sh android player` | JNI 库、授权 arm64 设备、SDK build-tools 36.0.0 和 `android` CLI；`--full` 扩展解码器矩阵 |
| Android Kotlin | `./scripts/test_native.sh android kotlin` | JDK，`GRADLE_BIN` 指向可用的 Gradle |
| iPad | `./scripts/test_native.sh ios` | XCFramework、模拟器 Debug 应用和已有 iPad 模拟器；可用 `IOS_TEST_DESTINATION` 选择设备 |
| Windows | `bash scripts/test_native.sh windows all` | 原生 fixture 和 Flutter 纹理测试，准备命令见下方 |
| Linux | `./scripts/test_native.sh linux all` | 开发依赖、Debug 应用；窗口测试另需 `xvfb`、`dbus-x11`、`openbox`、`xdotool` |
| ALAC | `./scripts/test_native.sh alac` | Clang/Clang++；可设置 `ALAC_SANITIZE=ON` |
| FFmpeg | `./scripts/test_native.sh ffmpeg` | FFmpeg 6+ 开发库、ffmpeg/ffprobe、pkg-config、Python 3；可设置 `FFMPEG_SANITIZE=ON` |

Windows 完整原生套件的准备与执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build_native.ps1 -Tests
flutter build windows --debug
cmake --build build/windows/x64 --config Debug --target windows_texture_test
bash scripts/test_native.sh windows all
```

同一配置的共享用例跑一次即可，例如 RTP 选择一个 host，Linux video/all 已包含共享 FFmpeg 视频用例。
硬件、sanitizer 和平台后端分别验证。Linux GPU 专项测试使用 `./scripts/test_native.sh linux gpu`。

### 应用集成测试

桌面基础套件只运行 `integration_test/desktop_test.dart` 中的一个完整 UI 流程，
只构建并启动一次测试应用：

```sh
flutter test -d macos integration_test/desktop_test.dart --reporter expanded
```

将 `macos` 换为 `windows` 或 `linux` 选择目标。Windows 在 Bash 中使用 `flutter.bat`。
使用隔离的 GUI 会话；
用例会隐藏、显示和调整真实应用窗口。Linux 使用 X11、Xvfb、Openbox 和 session D-Bus。
用例依次验证窗口隐藏/显示、打开裁剪、预览、应用裁剪，以及进入和退出全屏。
接收器使用测试替身，不需要真实投屏。预览不提交裁剪，应用后检查实际窗口比例。
裁剪边界、取消、键盘/TV 操作、控件计时及状态组合由 `flutter test` 验证，
不重复启动真实窗口。默认桌面套件不包含更新和安装测试。

Android 用例通过已启动的应用附加 driver，保留设备数据与权限：

```sh
flutter run -d <device-id> --target integration_test/android_receiver_restart_test.dart
```

在另一终端，将运行日志中的完整 VM service URI 设为 `RECEIVER_VM_SERVICE_URL`，
必要时用 `adb forward` 映射设备端口，然后执行：

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --use-existing-app="$RECEIVER_VM_SERVICE_URL"
```

清晰度验证使用 `integration_test/android_video_quality_test.dart`。
结束后用 `flutter run -d <device-id> --target lib/main.dart` 恢复普通入口。

[CI](.github/workflows/ci.yml) 先执行格式、静态检查、生成文件比对和 Dart 测试，
通过后在同一个 Ubuntu job 中按改动继续运行 Linux 回归，复用 Flutter 和构建环境。
该 job 成功后再按改动运行 macOS、Windows 和 Android 回归。手动触发可覆盖这四个平台。
桌面 CI 只运行上述一个 UI 集成流程，不再运行独立原生窗口或更新集成套件。
三个桌面平台都先由 `flutter test` 构建并运行集成用例，再运行原生测试。
macOS 和 Windows 复用其原生库和 Flutter 工程产物，Linux 宿主测试复用集成构建准备的 Flutter 引擎。
Ubuntu job 缓存 Dart 生成器和原生依赖的构建产物，按 runner 镜像、Flutter 版本和依赖锁文件隔离；
缓存命中后仍执行生成文件比对和全部测试。
Windows 同样缓存 Dart 原生依赖的构建产物，并额外按 MSVC 和 Windows SDK 版本隔离；
Dart 包由 `pub get --enforce-lockfile` 下载，避免恢复包缓存时大量小文件解压的开销。
CI 不额外构建普通桌面 Debug 应用；普通应用入口的打包验证在发布流程中执行。
iPad 测试、Release 打包和安装升级验证不在 CI 中执行，相关入口仍可手动使用。
播放和生命周期改动还应在对应设备上确认发现、画面、声音及重连。

## 调试

应用日志页可查看和导出 Flutter、协议与播放日志。
排查播放问题时保留异常前后的连续日志：`Playback pipeline` 定位接收、队列与解码，
`PCM queue` 定位音频消费，平台显示统计定位提交和取帧。
这些阶段的计数与实际屏幕呈现分别判断。

合成素材及生成器位于 `native/tests/fixtures/`，平台 fixture 位于各自测试目录。
日志、截图和单次验证记录放在 ignored `artifacts/`，构建与缓存保留在各自输出目录。

## 打包

| 平台 | 命令 | 输出 |
| --- | --- | --- |
| macOS | `./scripts/package_macos.sh` | `build/distribution/macos/`：app、arm64 DMG、校验和 |
| Android | `flutter build apk --release --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-release.apk` |
| iPad 编译检查 | `flutter build ios --release --no-codesign` | 无签名设备构建；模拟器使用 `flutter build ios --simulator --debug --no-codesign` |
| Windows | `powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/package_windows.ps1` | `build/distribution/windows/`：Setup、校验和 |
| Linux | `python3 scripts/package_linux.py` | `build/distribution/linux/`：`.deb`、bundle、校验和 |

Windows 打包需 Inno Setup 6.6+，可用 `AIRPLAY_ISCC` 指定 `ISCC.exe`。
Linux 发布包在 Ubuntu 24.04 x64 构建，另需 `dpkg-dev`、`fakeroot`、`desktop-file-utils`；
使用前述 `JAVA_HOME`。Windows 的 `-SkipBuild` 和 Linux 的 `--skip-build` 复用版本一致的 Release 产物。
许可与分发依赖见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Android 本地正式签名使用已有 keystore，设置以下环境变量后执行打包命令：

- `AIRPLAY_ANDROID_KEYSTORE_PATH`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

原地升级保持 application ID 和签名 key 一致，并递增版本。未配置签名时产物为未签名 APK。

## 发布

1. 比较前一个已发布稳定版以来的改动，同时更新 `pubspec.yaml` 和 [CHANGELOG.md](CHANGELOG.md)。文案按 [AGENTS.md](AGENTS.md#releases) 编写。
2. 语义版本和 BUILD 都应大于已发布稳定版，BUILD 范围为 1–65535。完成相关验证后提交版本改动。
3. 在该提交创建并推送 `vMAJOR.MINOR.PATCH` tag，触发 [Release assets](.github/workflows/release.yml)。

手动运行工作流用于构建 artifacts，`macos_only` 可选择仅构建 macOS。
Tag 发布生成平台安装包、`appcast.xml` 和校验和，上传校验完成后公开 Release。
失败时保留 draft，可重试同一 tag；已公开版本通过新版本修正。

| CI 签名配置 | 位置 / 内容 |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Repository secret；与仓库更新公钥对应的长期 Ed25519 私钥，Sparkle 导出的 Base64 32-byte seed，用于 macOS 和 Windows 更新签名 |
| `ANDROID_KEYSTORE_BASE64` | `android-release` Environment secret；已有正式 keystore 的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` | 同一 Environment 中的 keystore 凭据 |

Android 签名全部缺失时工作流跳过 APK，部分配置或签名错误使构建失败。
密钥及备份保存在仓库之外，后续发布沿用同一密钥。
本地 macOS 更新签名可使用已有钥匙串账户：

```sh
AIRPLAY_SPARKLE_ACCOUNT=flutter-airplay ./scripts/package_macos.sh
```

普通本地 macOS 打包使用仓库公钥；提供匹配的私钥或钥匙串账户后生成签名 appcast。

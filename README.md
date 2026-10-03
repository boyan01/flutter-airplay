# Flutter AirPlay

一个 GPLv3 开源的 AirPlay 接收器，用于在同一局域网内接收 iPhone 屏幕镜像。
macOS 和 Android 共用 Flutter 界面，接收协议与音视频播放由原生代码处理。

应用提供设备名设置、启动与停止接收、内嵌画面预览、全屏、主题切换和日志查看。
Android 还提供 TV 布局与遥控器方向键操作。当前 macOS 只维护应用内嵌播放。
不支持 DRM 内容，不承诺点对点连接。

当前版本为 **0.1.2+3**。这是仍在验证中的本地开发版本，尚未提供可独立分发的 macOS 安装包。

## 平台与验证范围

| 平台 | 当前实现 | 已记录的验证与限制 |
| --- | --- | --- |
| macOS | UxPlay 子进程接收，GStreamer 解码与音频播放，FlutterTexture 显示画面 | Apple Silicon 构建、合成回归与界面检查通过；当前内嵌版本有真实 iPhone 连接及解码事件，实际画面、声音和同步仍待确认；Intel 未验证 |
| Android 手机 | JNI 接收核心，MediaCodec/EGL 视频，Oboe 音频 | arm64 构建和原生回归通过；共享界面在真机完成启停、方向键与全屏检查；当前构建的 iPhone 音画播放仍待确认 |
| Android TV | 共用 Android 原生播放与 Flutter 界面，提供 TV 布局、焦点和 D-pad 操作 | 已做组件测试和手机方向键检查；未完成真实 TV 播放验收，当前仅打包 arm64-v8a |

当前构建的真实 iPhone 音画播放、同步、旋转、重连和持续稳定性仍需验证。
构建成功、接收状态和合成测试不能代替真机播放检查。

## 从源码运行

在仓库根目录执行以下命令。项目通过 `.fvmrc` 固定 Flutter **3.47.2**，
Dart 版本要求见 `pubspec.yaml`。使用 FVM 时，将下方 `flutter` 替换为 `fvm flutter`。

### macOS

需要 Xcode 的 macOS SDK，以及 CMake、pkg-config、libplist、OpenSSL 和 GStreamer。
当前构建在 Apple Silicon Mac 上使用 Homebrew 依赖：

```sh
brew install cmake pkg-config libplist openssl@3 gstreamer
flutter pub get
./scripts/build_receiver.sh
flutter run -d macos
```

也可以构建并启动 Release 应用：

```sh
flutter build macos --release
open "build/macos/Build/Products/Release/Flutter AirPlay.app"
```

原生脚本直接编译 `vendor/UxPlay/`，在 `build/uxplay-native/` 生成产物，
再复制到 `native/receiver/uxplay`。应用构建时将接收器放入应用资源目录，无需 `sudo make install`。
修改原生源码后，先重新运行原生脚本，再重新构建应用。

设置中的高级核心路径必须指向本项目提供事件协议的 `uxplay`。
普通 Homebrew UxPlay 不提供该协议，会导致启动超时。

### Android

当前原生构建脚本面向 macOS 开发环境，需要 Android SDK、
NDK **28.2.13676358** 和 SDK CMake **3.22.1**。
应用最低 Android API 为 **26**，当前只构建 **arm64-v8a**。

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
flutter pub get
./android/scripts/build_native.sh
flutter build apk --release --target-platform android-arm64
```

原生脚本按 `android/dependencies.lock.json` 获取并验证依赖，生成 JNI 播放库。
必须先构建 JNI，否则 APK 打包会失败并提示重建命令。

APK 输出为 `build/app/outputs/flutter-apk/app-release.apk`。
连接兼容的 Android 设备后，可安装：

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

当前 Release APK 使用本地 debug 签名。覆盖安装要保留数据，必须保持包名与签名一致。
这不是正式分发签名。原生依赖、构建与测试说明见 [Android 开发文档](docs/ANDROID.md)。

## 使用

1. 将 iPhone 与接收设备连接到同一局域网。
2. 打开应用，按需在设置中修改设备名，再点击“启动接收”。如出现局域网访问提示，允许访问。
3. 在 iPhone 控制中心打开“屏幕镜像”，选择应用显示的设备名。
4. 在应用内查看画面，声音由接收设备播放。点击展开按钮进入全屏预览。
5. 点击“停止投屏”或“停止接收”结束接收。修改设备名前先停止接收。

macOS 支持 `⌘R` 启停、`⌘F` 全屏、`⌘,` 设置、`⌘L` 日志，`Esc` 退出全屏。
Android 支持方向键与 Enter/Select；Back 优先关闭弹窗或退出全屏，退出全屏不会停止接收。

若设备无法被发现，先确认接收器处于等待状态、两端网络可互通，并查看应用日志。
“等待连接”表示服务已启动，不证明 iPhone 一定能发现它。
“已连接”也不代表画面和声音都已正常输出：macOS 收到媒体数据即可进入该状态，
Android 则在视频解码输出后进入该状态。实际播放仍需观察确认。

## 开发与回归

只有一个 Flutter 产品入口：`lib/main.dart`。代码按职责维护：

| 路径 | 职责 |
| --- | --- |
| `lib/`、`test/` | 共享界面、接收状态模型、平台通道与 Flutter 测试 |
| `macos/Runner/` | 接收子进程、帧传输、FlutterTexture 与 macOS 生命周期 |
| `android/app/src/main/` | Android 平台通道、JNI 接收、视频与音频播放 |
| `vendor/UxPlay/` | 两个平台共用的接收核心；直接维护源码 |
| `scripts/`、`android/tests/`、`android/scripts/` | 原生构建与合成回归 |
| `docs/` | 界面、平台接口与原生开发说明 |

macOS 目前使用软件 H.264 解码，将 BGRA 帧经私有 Unix socket 传给 Swift，
复制到 IOSurface CVPixelBuffer 后交给 FlutterTexture。尚未实现硬件解码或零拷贝。
Android 在应用进程内接收和播放。接收协议与平台播放保持边界，不引入 Go 组件。

Flutter 检查与 macOS 原生回归：

```sh
flutter analyze
flutter test
./scripts/build_receiver.sh
./scripts/test_native.sh "$PWD/native/receiver/uxplay"
./scripts/test_frames.sh
./scripts/test_audio.sh
./scripts/test_sync.sh
./scripts/test_rtp.sh
./scripts/test_recovery.sh
flutter build macos --release
```

Android 接收核心的主机合成回归：

```sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" ./android/scripts/test_host.sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" HOST_SANITIZE=ON ./android/scripts/test_host.sh
```

涉及共享接收核心的修改，需要验证 macOS 与 Android 构建及相关回归。
这些测试覆盖生命周期、帧传输、音频解码、时钟调度、RTP 重启与恢复等行为，使用合成输入。
合成回归不能证明真机播放效果；日志与截图保存在忽略的 `artifacts/` 中。

## 分发与许可

macOS Debug/Profile/Release 当前均为非沙箱的本地开发应用，依赖本机 Homebrew 动态库与插件。
不能直接将 `.app` 复制给没有这些依赖的 Mac。独立分发还需要依赖打包、
Developer ID 签名、公证和局域网权限验收。
应用不会修改系统 AirPlay Receiver、防火墙、系统音量或凭据。

项目使用 [GPLv3](LICENSE)。分发时保留第三方版权与许可声明，并履行相应源码义务。
第三方来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，
UxPlay 上游版本与基准 commit 见 [UPSTREAM.md](vendor/UxPlay/UPSTREAM.md)。

更多说明：[共享界面](docs/UI.md) · [Android 平台接口](docs/ANDROID_UI.md) ·
[Android 原生开发](docs/ANDROID.md)。

# iPad 前台接收宿主

使用根 `lib/main.dart` 和共享 C++ 接收、时间线与播放状态。iPad 以
VideoToolbox 解码 H.264；硬件 HEVC 解码可用时宣告并接收 HEVC。
AudioConverter 解码 ALAC、AAC-LC、AAC-ELD，
RemoteIO 输出 PCM，CVPixelBuffer 直接交给 Flutter texture。

要求 iPadOS 15 或更新版本。应用需要本地网络访问权限；Bonjour 发布
`_airplay._tcp` 和 `_raop._tcp`。保持应用在前台，并与 iPhone 位于同一局域网。
退到后台会撤销服务并关闭接收/播放；返回前台恢复此前开启的接收状态。
音频中断和路由变化会结束当前连接并重建接收，需要发送端重新连接。
不提供后台空闲待命，不支持 DRM，不承诺 App Store 分发。

## 从源码构建

在 Apple Silicon Mac 上使用 Xcode、CMake、Python 3、Perl 和根 `.fvmrc`
固定的 Flutter SDK。全部命令从仓库根执行：

```sh
flutter pub get
./ios/scripts/build_native.sh
flutter build ios --simulator --debug --no-codesign
flutter build ios --release --no-codesign
```

原生脚本校验 `android/dependencies.lock.json` 中的源码，分别构建 arm64
设备与 arm64 模拟器的静态库，然后生成
`build/ios-native/AirplayPlayer.xcframework`。目前不提供 Intel 模拟器归档。
Xcode 直接链接此静态归档和系统框架；应用内包含根工程的许可证资产。
无签名设备构建用于编译验证，不能直接安装；设备安装需另行选择授权签名。
本地开发工程不保存团队或签名账户。

## 合成媒体回归

先完成模拟器应用构建，再运行：

```sh
./ios/scripts/test_player.sh
# Optional: choose an existing simulator destination.
IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPad (A16),OS=latest' ./ios/scripts/test_player.sh
```

脚本选择本机已有 iPad 模拟器，结果保存在 ignored `artifacts/ios/`。
XCTest 使用合成 H.264 / HEVC 像素、AAC/ALAC/ELD packet 和全零 PCM，不调节系统音量；
HEVC 覆盖横竖屏、4K、Main10 和 H.264 重连；模拟器没有 HEVC 硬解时明确跳过。
测试启动参数关闭应用自动接收。合成结果和无签名构建不能证明真实 iPhone
发现、图像、可听声音、音画同步或目标 iPad 的性能。

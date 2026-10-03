# Windows 宿主

Windows 实现继续运行根目录 `lib/main.dart` 和共享 C++ 播放器。当前代码使用
Windows 10+ 的 Media Foundation H.264 / AAC-LC、内置 Apple ALAC、WASAPI
和系统 DNS-SD；窗口内的 Flutter 纹理显示镜像，不创建额外播放器窗口。

目前没有 Windows SDK / 运行环境的目标构建或真机 AirPlay 验证。此目录提供
实现与可执行的 Windows 构建、回归入口，不能据此认为 Windows 已通过验收。

```text
+--------------------------------------------------+
| System window bar                     [_] [ ] [X]|
| Flutter AirPlay                      [Settings]  |
|                                                  |
|          Existing waiting / mirrored page        |
|                                                  |
| [Receive: ON]                    [Disconnect]    |
+--------------------------------------------------+
```

## 构建

在 Windows x64 的 Visual Studio 2022 Native Tools 环境安装 C++ 桌面开发、
Windows 10/11 SDK、Visual Studio Clang tools、CMake、Git 和 Perl。
原生库使用 ClangCL 编译 C 接收核心并生成兼容 MSVC 的 DLL/import library；
Flutter 宿主继续使用标准 Windows 工具链。线程与 socket 兼容层不依赖
MSYS2、pthread DLL 或 Apple Bonjour DLL。

从仓库根目录运行固定版本 Flutter，再构建原生库和宿主：

```powershell
fvm flutter pub get
powershell -File windows/scripts/build_native.ps1 -Tests
fvm flutter build windows --release
```

脚本从 `android/dependencies.lock.json` 获取固定 OpenSSL / libplist 源码并核对
commit，使用 `vendor/UxPlay/` 和 `vendor/alac/`。依赖和构建产物位于 ignored
`build/windows-deps/`、`build/windows-native/`。Flutter 打包在原生 DLL 缺失时
会失败，不生成缺少播放器的应用。构建脚本不下载预编译 codec，不修改防火墙。

## 当前媒体范围

- H.264：系统同步 MFT 输出 NV12，由 CPU 转 RGBA 后接入 Flutter
  `PixelBufferTexture`。支持码流参数变化、解码队列 generation 和 FLUSH。
  当前不声称 GPU 解码、零拷贝或 60 FPS 性能已验证。
- ALAC：复用现有内置 decoder 和 AirPlay 配置；共享 PCM 队列输出至 WASAPI。
- AAC-LC：系统 MFT 使用当前 44.1 kHz、双声道、16-bit PCM 配置。
  Microsoft decoder 仅支持 1024 样本帧，960 样本帧明确拒绝。
- AAC-ELD：当前明确拒绝并产生错误。RAOP TXT 仅声明 `cn=1,2`，但这不保证
  iPhone 镜像会采用其他音频格式；因此不能承诺 iPhone 镜像有声音。
- WASAPI：共享模式使用系统采样率转换；默认输出设备变化和失效后重开。
  实际可听声音、设备延迟与音画同步仍需 Windows 验证。
- Windows N 需要 Media Feature Pack。缺少系统 decoder 时不能播放相应媒体。

下一步补齐 ELD 可以采用固定版本、仅 AAC decoder 的 FFmpeg `avcodec` /
`avutil`，复用 Linux 的已验证有限 ELD 配置。仍需 Windows 编译与同样的
codec fixtures；不能把该建议算成当前支持，也不能从有限 ELD 样本推导完整
SBR / ER 支持。

## 发现与生命周期

使用 Windows `DnsServiceRegister` 发布 `_airplay._tcp` / `_raop._tcp`，等候
异步注册结果后才进入等待状态。停止时撤销服务，保留本地随机 identity 与
配对密钥。配置只写当前用户的 LocalAppData 目录。接收核心的 `int` descriptor
映射到全宽 Windows `SOCKET`，避免 x64 句柄截断；原生线程退出前加入所有工作。

现有 UI 的全屏命令保存并恢复窗口 placement / style。系统标题栏保持标准
行为；首版未加入托盘、开机启动或 Windows 系统权限管理。

## 验证入口与缺口

`build_native.ps1 -Tests` 构建并执行：

- `windows_pixels`：合成 NV12 的黑/白/红色、BT.601 / BT.709、limited / full
  range、行填充和畸形缓冲输入。
- `windows_compat`：Windows UDP loopback、descriptor/fd_set 映射、可加入线程
  和带锁 condition wait。

像素转换 fixture 可在 macOS 用 C++17 与 ASan/UBSan 独立运行。该结果只证明
颜色转换与缓冲边界逻辑，不证明 Windows MFT、WASAPI、DNS-SD 或 Flutter 纹理。
Windows 仍需目标构建、codec fixture 和真实 iPhone 的发现/握手/画面/音频/
暂停恢复/断开重连/尺寸方向变化/网络变化验证。正常接收流量所需的 Windows
防火墙策略由用户/部署环境配置，本代码不自动更改系统网络规则。

API 依据：[AAC decoder](https://learn.microsoft.com/en-us/windows/win32/medfound/aac-decoder)、
[H.264 decoder](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder)、
[Windows DNS-SD](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsserviceregister)、
[Flutter texture registrar](https://api.flutter.dev/windows-embedder/flutter__texture__registrar_8h_source.html)。

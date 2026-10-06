# Flutter AirPlay

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL%20v3-blue.svg" alt="License: GPL v3"></a>
  <img src="https://img.shields.io/badge/Platform-macOS%20|%20Android%20|%20Windows%20|%20Linux%20|%20iPad-lightgrey.svg" alt="Platform Support">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B.svg?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Version-0.1.2%2B3-brightgreen.svg" alt="Version">
</p>

<p align="center">
  <a href="README.md"><b>English</b></a> | <a href="README_ZH.md"><b>简体中文</b></a>
</p>

基于 Flutter 与 C++ 开发的开源 AirPlay 屏幕镜像接收器。支持在同一局域网内接收来自 iPhone、iPad 和 Mac 的屏幕镜像与音频流。

项目复用共享 C++ 播放核心与 [UxPlay](vendor/UxPlay/UPSTREAM.md) 协议实现，跨移动端、电视和桌面平台提供原生硬件加速的高性能流媒体播放体验。

---

## 📸 界面预览

<!-- 截图占位：待后续补充真实截图 / Demo GIF -->
```text
+-----------------------------------------------------------------+
| [-] [+] [x]                  Flutter AirPlay                    |
+-----------------------------------------------------------------+
|                                                                 |
|                            [ 📺 ]                               |
|                                                                 |
|                        Living Room TV                           |
|                         ● 等待连接...                           |
|                                                                 |
|               +-----------------------------------+             |
|               |  1. 将 iPhone 与本机连入同一 Wi-Fi |             |
|               |  2. 在 iPhone 控制中心打开屏幕镜像 |             |
|               |  3. 选择 "Living Room TV" 开始投屏|             |
|               +-----------------------------------+             |
|                                                                 |
|           [ 接收开关: ON ]      [ ⚙ 设置 ]      [ 📋 日志 ]       |
+-----------------------------------------------------------------+
```

```text
+-----------------------------------------------------------------+
| [iPhone]                                              [-] [+] [x]|
|                                                                 |
|                                                                 |
|                       [ 正在镜像的画面 ]                        |
|                     (自动保持原始比例缩放)                       |
|                                                                 |
|                                                                 |
|            +---------------------------------------+            |
|            |  [⏏ 断开投屏]   [📌 窗口置顶]   [⛶ 全屏]  |            |
|            +---------------------------------------+            |
+-----------------------------------------------------------------+
```

---

## ✨ 核心特性

- **⚡ 原生硬件解码**：macOS / iPad 采用 Apple VideoToolbox，Android 采用 NDK MediaCodec 硬解，流畅低延迟。
- **📱 全终端界面适配**：统一的 Flutter 界面，无缝适应手机小屏、桌面窗口管理器以及大屏 Android TV。
- **📺 专为电视打造**：专属 10 尺大屏 UI、遥控器方向键导航、随焦点移动的统一白色圆角边框、强制深色主题、前台运行保持屏幕常亮。
- **🪟 桌面深度集成**：播放窗口自适应画面比例；支持窗口置顶、全屏、系统托盘 / 菜单栏后台常驻以及开机自启。
- **🔄 后台无缝接收**：Android 支持前台服务与系统通知控制，切到后台或息屏后仍可继续接收投屏。
- **🎯 动态分辨率自协商**：支持“适配本机”（最高请求 4K 2160p）、1440p、1080p 与 720p 档位，实时显示屏幕像素与接收尺寸。
- **🔒 开箱即用与零膨胀**：macOS 打包内置全部原生依赖，无需通过 Homebrew 安装额外运行时或 GStreamer。
- **播放统计**：所有平台都可在「设置 → 高级 → 播放统计图层」开启。图层不拦截操作，显示编码格式、解码后端、实际尺寸、每秒调度提交帧率、累计调度丢帧和队列深度。丢帧统计自上次播放重置起的过期、乱序和溢出画面，不包含生命周期取消及网络丢包；提交帧率不代表屏幕实际呈现帧率。

---

## 🖥️ 平台支持矩阵

### 正式支持平台

| 平台 | 支持级别 | 视频解码 | 音频解码 | 说明与特性 |
| :--- | :---: | :--- | :--- | :--- |
| **macOS** | ✅ 支持 | VideoToolbox (H.264 / HEVC) | AudioConverter / CoreAudio (AAC-LC, ALAC) | macOS 12+ (Apple Silicon)。内置依赖；支持菜单栏常驻与登录自启。 |
| **Android 手机** | ✅ 支持 | MediaCodec (H.264 / HEVC) | MediaCodec (AAC, AAC-ELD), 内置 ALAC | Android 8.0+ (API 26+)，`arm64-v8a`。前台服务后台待命；原生 SurfaceView 渲染。 |
| **Android TV** | ✅ 支持 | MediaCodec (H.264 / HEVC) | MediaCodec (AAC, AAC-ELD), 内置 ALAC | `arm64-v8a`。遥控器方向键焦点适配、电视深色主题、前台保持屏幕常亮。 |

### 实验性平台

| 平台 | 支持级别 | 视频解码 | 音频解码 | 限制与说明 |
| :--- | :---: | :--- | :--- | :--- |
| **iPad** | 🧪 实验性 | VideoToolbox (H.264 / HEVC) | AudioConverter (AAC-LC, AAC-ELD, ALAC) | iPadOS 15+。仅前台接收；切至后台停止接收。音频中断需重新连接。 |
| **Windows** | 🧪 实验性 | Media Foundation (H.264 / HEVC)，包内 FFmpeg 备用 | Wasapi / 包内解码器 | Windows 10+ x64。Windows N 版本需安装 Media Feature Pack。支持托盘与快捷键。 |
| **Linux 桌面** | 🧪 实验性 | 系统 FFmpeg 6+ (软解) | PulseAudio / PipeWire, ALAC | 依赖 GTK 3、Avahi mDNS、PulseAudio/PipeWire。托盘通过 session D-Bus 的 StatusNotifierItem 显示。 |

> [!NOTE]
> **DRM 说明**：由于硬件级版权保护链限制，应用**不支持**播放具有 FairPlay DRM 保护的流媒体内容（如 Netflix、Apple TV+、Disney+ 等，投屏时将显示黑屏）。不支持 Wi-Fi Direct 点对点直连，发送端与接收端必须位于同一局域网。

---

## 🚀 快速上手

1. **连接到同一网络**：确保 iPhone / iPad / Mac 与接收设备处于同一个 Wi-Fi 或局域网子网中。
2. **启动应用**：打开 Flutter AirPlay，接收服务默认自动启动（如弹出系统局域网访问权限，请点击“允许”）。
3. **发起镜像**：
   - iOS / iPadOS：滑出**控制中心**，点击**屏幕镜像**，选择界面上显示的设备名称。
   - macOS：打开顶部菜单栏**控制中心** > **屏幕镜像** > 选择设备名称。
4. **播放与控制**：
   - 收到视频帧后，应用将自动无缝切入播放页面。
   - 点击屏幕、移动鼠标或按遥控器任意导航键即可唤出控制栏。
   - 点击 **断开投屏** 可结束当前连接并返回待命页。

---

## ⌨️ 快捷键与操作指南

### 桌面端快捷键

| 操作 | macOS | Windows / Linux |
| :--- | :---: | :---: |
| **启停接收器** | `⌘ + R` | `Ctrl + R` |
| **偏好设置** | `⌘ + ,` | `Ctrl + ,` |
| **查看日志** | `⌘ + L` | `Ctrl + L` |
| **断开当前连接** | `⌘ + .` | `Ctrl + .` |
| **切换全屏** | `⌃ + ⌘ + F` | `F11` |
| **退出全屏** | `Esc` | `Esc` |
| **关闭窗口** | `⌘ + W` | `Ctrl + W` |
| **退出程序** | `⌘ + Q` | `Ctrl + Q` |

- **鼠标交互**：双击画面切换全屏。鼠标静止 2.5 秒后控制栏自动渐隐淡出。

### 移动端与 TV 操作

- **Android 手机**：控件闲置 3 秒后自动隐藏。系统 `Back` 键优先隐藏控件；控件隐藏状态下按 `Back` 显示断开提示，2 秒内再次按 `Back` 方可断开。
- **Android TV**：按遥控器 `OK`、`方向键` 或 `Menu` 键唤出浮层。默认焦点落在 **“继续观看”**，防止误触断开；5 秒无操作自动隐藏。`Back` 键仅用于显隐控制层，不会直接中断播放。

---

## ⚙️ 核心设置与进阶功能

- **设备名称**：自定义在 mDNS / Bonjour 广播中显示的名称。支持自动保存、随机名称生成和一键重置为系统默认设备名。
- **快速匹配（高级）**：所有平台均提供，默认关闭。开启后不再公布旧版配对能力，尝试缩短连接等待。等待连接时自动生效；正在投屏时，当前连接结束后生效。如果发送端无法连接，可关闭此选项。
- **清晰度偏好**：提供 **适配本机**、**720p**、**1080p**、**1440p** 与 **4K (2160p)** 档位。
  - “适配本机”根据屏幕实际分辨率与解码器能力动态请求最适尺寸。
  - 修改清晰度在空闲时自动生效；在已有连接时保留当前流，在会话结束后自动应用。
- **桌面专属设置 (macOS & Windows)**：
  - **窗口置顶**：播放时窗口固定在最上层。
  - **连接时显示/全屏**：收到投屏信号时自动将窗口前置或进入全屏。
  - **系统托盘 / 菜单栏常驻**：关闭主窗口后继续在后台静默待命。
  - **开机自启动**：跟随操作系统启动自动运行后台服务。
- **Android 后台接收权限**：
  - 需要允许**通知权限**（Android 13+），以保持前台保活服务常驻。
  - 建议在系统设置中授予**“显示在其他应用上层”（悬浮窗）**权限，以便在后台收到投屏时能够自动唤起播放页面。

---

## 🔍 常见问题与故障排查

<details>
<summary><b>1. iPhone 屏幕镜像列表中找不到此设备</b></summary>

- **AP 隔离 / 访客网络**：请检查无线路由器设置，确保未开启“AP 隔离”或“访客模式”（这会阻止局域网内设备间的 mDNS 互通）。
- **防火墙与本地网络权限**：macOS / iOS / Windows 上首次启动时需允许应用的“局域网访问”权限。
- **Linux 发现服务**：Linux 依赖 `avahi-daemon`，请确认服务已正常运行（`systemctl status avahi-daemon`）。
- **接收器状态**：确认应用首页状态显示为 **“等待连接”**，而非错误或停止状态。
</details>

<details>
<summary><b>2. 已建立连接但黑屏或只有音频</b></summary>

- **版权保护内容 (DRM)**：AirPlay 镜像协议无法接收受 FairPlay DRM 保护的商业媒体（如 Netflix、Disney+、Apple TV+ 等），发送端在播放此类视频时会自动输出黑屏，属于正常限制。
- **编码器协商**：确认接收设备硬件解码器支持相应分辨率与编码格式，最终编码由发送端根据握手协商确定。
</details>

<details>
<summary><b>3. 应用日志在何处查看与导出？</b></summary>

日志通过 `mixin_logger` 自动记录并滚动保存（最多保留 10 个文件，每个 5 MiB），包含 Flutter 界面、协议核心与解码诊断：
- **macOS**：`~/Library/Application Support/tech.soit.flutterairplay/logs/`
- **Android**：`Android/data/tech.soit.flutterairplay/files/logs/`
- **应用内查看**：在首页或设置页点击 **日志** 入口即可直接翻阅或导出最新日志。
</details>

---

## 🏗️ 技术架构

```text
Flutter UI / ReceiverModel
          |
ReceiverRepository (设置持久化 / native 操作)
          |
lib/receiver/native + native/ffi (C ABI / Dart port)
          |
native/receiver (状态 / 期望与生效设置 / 生命周期)
          |                          |
native/protocol                native/playback
          |                          |
     vendor/UxPlay             native/backends
                               Apple / Android / Windows / Linux / FFmpeg
```

关于本地开发环境搭建、各平台构建命令、原生测试矩阵与 CI 工作流，请参考 [开发指南 (DEVELOPMENT.md)](DEVELOPMENT.md)。代码设计规范与贡献约定参见 [AGENTS.md](AGENTS.md)。

---

## 📄 开源许可与上游声明

- 本项目采用 [GNU General Public License v3.0 (GPLv3)](LICENSE) 开源许可协议。
- 接收协议部分衍生自 [UxPlay](vendor/UxPlay/UPSTREAM.md)，上游版本基准与 commit 记录维护于 `vendor/UxPlay/UPSTREAM.md`。
- 第三方依赖与开源许可声明详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

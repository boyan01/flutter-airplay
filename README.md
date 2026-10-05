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

An open-source AirPlay mirroring receiver built with Flutter and C++. It enables devices on the same local network to receive screen mirroring and audio from iPhones, iPads, and Macs.

Powered by a shared C++ playback core and [UxPlay](vendor/UxPlay/UPSTREAM.md) protocol implementation, Flutter AirPlay delivers high-performance streaming with native hardware acceleration across mobile, TV, and desktop platforms.

---

## 📸 Preview

<!-- SCREENSHOT PLACEHOLDER: Replace with actual screenshots / demo GIF when available -->
```text
+-----------------------------------------------------------------+
| [-] [+] [x]                  Flutter AirPlay                    |
+-----------------------------------------------------------------+
|                                                                 |
|                            [ 📺 ]                               |
|                                                                 |
|                        Living Room TV                           |
|                         ● Ready to connect                      |
|                                                                 |
|               +-----------------------------------+             |
|               |  1. Connect to the same Wi-Fi     |             |
|               |  2. Open Control Center on iPhone |             |
|               |  3. Tap Screen Mirroring          |             |
|               |  4. Select "Living Room TV"       |             |
|               +-----------------------------------+             |
|                                                                 |
|           [ Receiver: ON ]       [ ⚙ Settings ]      [ 📋 Logs ] |
+-----------------------------------------------------------------+
```

```text
+-----------------------------------------------------------------+
| [iPhone]                                              [-] [+] [x]|
|                                                                 |
|                                                                 |
|                     [ Mirrored Screen Frame ]                   |
|                   (Aspect ratio matched automatically)          |
|                                                                 |
|                                                                 |
|            +---------------------------------------+            |
|            |  [⏏ Disconnect]  [📌 Always on Top]  [⛶ Fullscreen] |
|            +---------------------------------------+            |
+-----------------------------------------------------------------+
```

---

## ✨ Features

- **⚡ Native Hardware Acceleration**: Hardware-accelerated video decoding via Apple VideoToolbox (macOS/iPad) and Android NDK MediaCodec.
- **📱 Phone, Tablet, TV & Desktop**: Unified Flutter interface adapting seamlessly to handheld screens, desktop window managers, and large TV displays.
- **📺 Android TV Optimized**: Dedicated 10-foot UI with remote D-pad navigation, dark mode by default, and screen stay-awake support.
- **🪟 Desktop-Friendly Integration**: Window aspect ratio automatically tracks video stream; supports always-on-top, fullscreen, system tray / menu bar persistence, and launch at login.
- **🔄 Background Reception**: Android runs as a foreground service with notification controls, continuing reception when switched to the background or screen-off.
- **🎯 Dynamic Resolution & Auto-negotiation**: Supports "Match Native" (up to 4K 2160p), 1440p, 1080p, and 720p with real-time stream dimension monitoring.
- **🔒 Zero Bloat & Bundled Dependencies**: No need to install Homebrew packages or GStreamer runtime on macOS.

---

## 🖥️ Platform Support Matrix

### Production Platforms

| Platform | Tier | Video Decoder | Audio Decoder | Remarks |
| :--- | :---: | :--- | :--- | :--- |
| **macOS** | ✅ Supported | VideoToolbox (H.264 / HEVC) | AudioConverter / CoreAudio (AAC-LC, ALAC) | macOS 12+ (Apple Silicon). Bundled native libraries; menu bar tray & launch at login support. |
| **Android Phone** | ✅ Supported | MediaCodec (H.264 / HEVC) | MediaCodec (AAC, AAC-ELD), Built-in ALAC | Android 8.0+ (API 26+), `arm64-v8a`. Foreground service for background standby; SurfaceView rendering. |
| **Android TV** | ✅ Supported | MediaCodec (H.264 / HEVC) | MediaCodec (AAC, AAC-ELD), Built-in ALAC | `arm64-v8a`. Full TV remote / D-pad focus handling, enforced dark theme, screen kept awake. |

### Experimental Platforms

| Platform | Tier | Video Decoder | Audio Decoder | Limitations & Notes |
| :--- | :---: | :--- | :--- | :--- |
| **iPad** | 🧪 Experimental | VideoToolbox (H.264 / HEVC) | AudioConverter (AAC-LC, AAC-ELD, ALAC) | iPadOS 15+. Foreground reception only; stops when switched to background. |
| **Windows** | 🧪 Experimental | Media Foundation (H.264 / HEVC), FFmpeg fallback | Wasapi / Bundled decoders | Windows 10+ x64. Windows N requires Media Feature Pack. System tray and shortcuts supported. |
| **Linux Desktop** | 🧪 Experimental | System FFmpeg 6+ (Software) | PulseAudio / PipeWire, ALAC | Requires GTK 3, Avahi mDNS, PulseAudio/PipeWire. System tray requires AppIndicator. |

> [!NOTE]
> **DRM Notice**: Screen mirroring protected by FairPlay DRM (such as Netflix, Apple TV+, Disney+) is **not supported** due to hardware DRM chain restrictions. Peer-to-peer (Wi-Fi Direct / Ad-hoc) connection is not supported; both devices must be on the same local network.

---

## 🚀 Quick Start

1. **Connect to Same Network**: Ensure your iPhone/iPad/Mac and the receiver device are connected to the same local Wi-Fi or subnet.
2. **Launch Application**: Open Flutter AirPlay. The receiver starts automatically upon launch. (Grant local network permission if prompted).
3. **Start Mirroring**:
   - On iOS / iPadOS: Swipe to open **Control Center**, tap **Screen Mirroring**, and select the device name displayed on the screen.
   - On macOS: Open **Control Center** > **Screen Mirroring** > select the receiver name.
4. **Playback & Controls**:
   - The app automatically switches to the player screen once video frames are received.
   - Tap the screen, move the mouse, or press any remote navigation button to reveal on-screen controls.
   - Click **Disconnect** to end mirroring and return to standby.

---

## ⌨️ Controls & Shortcuts

### Desktop Shortcuts

| Action | macOS | Windows / Linux |
| :--- | :---: | :---: |
| **Toggle Receiver** | `⌘ + R` | `Ctrl + R` |
| **Settings** | `⌘ + ,` | `Ctrl + ,` |
| **Logs** | `⌘ + L` | `Ctrl + L` |
| **Disconnect Session** | `⌘ + .` | `Ctrl + .` |
| **Toggle Fullscreen** | `⌃ + ⌘ + F` | `F11` |
| **Exit Fullscreen** | `Esc` | `Esc` |
| **Close Window** | `⌘ + W` | `Ctrl + W` |
| **Quit Application** | `⌘ + Q` | `Ctrl + Q` |

- **Mouse Interaction**: Double-click video to toggle fullscreen. On-screen controls automatically fade after 2.5 seconds of inactivity.

### Mobile & TV Navigation

- **Android Phone**: Controls fade after 3 seconds. The system `Back` button hides controls first. Pressing `Back` again within 2 seconds confirms disconnection.
- **Android TV**: Press `OK`, `Direction keys`, or `Menu` to reveal controls. Initial focus rests on **"Continue watching"** to prevent accidental disconnections. Controls fade after 5 seconds. `Back` button toggles controls and never abruptly disconnects.

---

## ⚙️ Settings & Configuration

- **Device Name**: Customize the receiver name visible via mDNS/Bonjour. Supports auto-saving, random name generation, and one-click reset to device default.
- **Video Quality Preference**: Choose from **Match Native**, **720p**, **1080p**, **1440p**, or **4K (2160p)**.
  - "Match Native" queries your display resolution and decoder limits to request optimal dimensions.
  - Resolution changes take effect immediately during standby, or seamlessly after the active streaming session ends.
- **Desktop Preferences (macOS & Windows)**:
  - **Always on Top**: Keeps player window pinned above other desktop applications.
  - **Show / Fullscreen on Connect**: Automatically brings window to front or enters fullscreen upon stream arrival.
  - **System Tray / Menu Bar**: Keeps receiver running quietly in the background when the main window is closed.
  - **Launch at Login**: Starts receiver service automatically on OS startup.
- **Android Background Reception**:
  - Requires **Notification Permission** (Android 13+) to post the persistent foreground service notice.
  - Enable **"Display over other apps"** in system settings to allow Flutter AirPlay to automatically open when mirroring starts from the background.

---

## 🔍 Troubleshooting & FAQ

<details>
<summary><b>1. Device not found in Screen Mirroring list</b></summary>

- **Network Isolation**: Ensure your Wi-Fi router does not have "AP Isolation" or "Guest Mode" enabled, which blocks mDNS discovery between devices.
- **Firewall & Permissions**: Allow local network access for Flutter AirPlay on macOS / iOS / Windows.
- **mDNS Service**: On Linux, ensure the `avahi-daemon` service is running (`systemctl status avahi-daemon`).
- **Receiver State**: Verify that the homepage status indicator displays **"Ready to connect"** / **"Discoverable"** and is not in an error state.
</details>

<details>
<summary><b>2. Connected but black screen or audio only</b></summary>

- **DRM Content**: AirPlay mirroring does not support copyright-protected media (e.g. Netflix, Disney+, Apple TV+). The sender device will output a black screen by design.
- **Codec Negotiation**: Ensure your device supports the requested codec. The sender decides the final stream format based on receiver negotiation.
</details>

<details>
<summary><b>3. Where are the diagnostic logs saved?</b></summary>

Logs are written using `mixin_logger` (retaining up to 10 files, 5 MiB each) and contain Flutter, protocol core, and decoder diagnostics:
- **macOS**: `~/Library/Application Support/tech.soit.flutterairplay/logs/`
- **Android**: `Android/data/tech.soit.flutterairplay/files/logs/`
- **In-App**: Open the **Logs** screen from the homepage or settings to view and export recent events.
</details>

---

## 🏗️ Technical Architecture

```text
+-------------------------------------------------------------+
|                     Flutter UI Layer                        |
|  (lib/ui/ - Responsive design for TV, Mobile, and Desktop)  |
+-------------------------------------------------------------+
                              │ MethodChannel / Events
+-------------------------------------------------------------+
|              Receiver Repository & Model                    |
|             (lib/receiver/ - Lifecycle & State)             |
+-------------------------------------------------------------+
                              │ Native Bridge (JNI / C-FFI / ObjC)
+-------------------------------------------------------------+
|            Shared C++ Player Core (native/player/)          |
|    - Timestamp synchronization & Jitter buffer              |
|    - Session recovery & Lifecycle management                |
+-------------------------------------------------------------+
               │                                      │
+──────────────────────────────+      +───────────────────────────────+
|   UxPlay Protocol Engine     |      |    Platform Hardware Output   |
|   (vendor/UxPlay/)           |      | - VideoToolbox / CoreAudio    |
| - AirPlay Mirroring Server   |      | - NDK MediaCodec / Oboe       |
| - RTSP, RTP, FairPlay Handshake |   | - Media Foundation / FFmpeg   |
+──────────────────────────────+      +───────────────────────────────+
```

For environment setup, local compilation, tests, and CI packaging, please refer to the [Development Guide (DEVELOPMENT.md)](DEVELOPMENT.md). Codebase architecture and coding standards are documented in [AGENTS.md](AGENTS.md).

---

## 📄 License & Upstream

- This project is licensed under the [GNU General Public License v3.0 (GPLv3)](LICENSE).
- Incorporates code from [UxPlay](vendor/UxPlay/UPSTREAM.md); upstream details and commits are tracked in `vendor/UxPlay/UPSTREAM.md`.
- Third-party licenses and notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

# Changelog

## 0.1.5

### 中文

- macOS 新增应用内更新：默认自动检查，可在设置中手动检查、查看更新说明、下载及安装重启；关闭更新面板后下载继续，投屏中安装前会请求确认。0.1.4 及更早版本需先手动升级一次，其他平台仍需手动更新。
- 各平台新增播放缓冲设置，可选择平台默认值或 40–300 毫秒预设，音视频共用缓冲；设置在等待接收时或当前连接结束后生效。
- macOS 视频改用原生定时显示，改进桌面窗口随画面尺寸及旋转调整的行为，并新增原始尺寸和适应屏幕快捷键。
- 改进各平台视频调度，积压时合并已到期画面，减少恢复播放时显示陈旧画面；新增 macOS 和 Android 显示时序诊断。
- macOS、Windows 和 Linux 托盘菜单显示接收名称、连接状态及发送设备，提供接收与断开操作；启用关闭到托盘时，隐藏窗口后继续音视频播放。
- 修复桌面退出时原生回调未及时清理导致的崩溃。

### English

- Added in-app updates on macOS with automatic checks enabled by default, manual checks, release notes, downloads, and installation with restart. Downloads continue after closing the update panel, and installation asks for confirmation during a connection. Versions 0.1.4 and earlier require one manual upgrade first; other platforms still require manual updates.
- Added playback buffer settings on all platforms, offering platform defaults or presets from 40 to 300 ms shared by audio and video. Changes apply while waiting for a connection or after the current connection ends.
- Switched macOS video to native timed display, improved desktop window sizing and rotation behavior, and added Actual Size and Fit to Screen keyboard shortcuts.
- Improved video scheduling on all platforms by coalescing overdue frames during backlogs to reduce stale pictures when playback recovers. Added display timing diagnostics on macOS and Android.
- Updated macOS, Windows, and Linux tray menus to show the receiver name, connection status, and sender, with reception and disconnect controls. Audio and video continue when the window is hidden with close-to-tray enabled.
- Fixed desktop exit crashes caused by native callbacks remaining registered during shutdown.

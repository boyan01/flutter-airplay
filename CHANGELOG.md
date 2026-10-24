# Changelog

## 0.1.11

### 中文

- Android TV 用遥控器切换时，焦点框平滑移动，选中项轻微放大，列表也会平滑滚动。
- Android TV 首页的清晰度和延迟各自打开对应选项，选好后自动返回。

### English

- On Android TV, the focus outline now glides between items, the focused item grows slightly, and lists scroll smoothly.
- On the Android TV home screen, quality and latency each open their own options and return once you choose.

## 0.1.10

### 中文

- 降低投屏延迟；Android TV 会请求低延迟画面模式，部分联发科电视的音频不再退回高延迟输出。
- Android TV 自动画质可识别 4K 面板，不再被限制在 1080p。
- Android TV 首页新增画面设置，启动时不再闪白屏或闪现手机布局，TCL 和雷鸟桌面显示应用横幅。

### English

- Lower mirroring latency; Android TVs request low-latency picture mode, and some MediaTek TVs no longer fall back to high-latency audio output.
- Auto quality on Android TVs now detects 4K panels instead of capping at 1080p.
- Added picture settings to the Android TV home screen, removed the white or phone-layout flash at launch, and show the app banner on TCL and Thunderbird launchers.

## 0.1.9

### 中文

- 视频解码出错时自动恢复，不再中断投屏。
- 播放工具栏新增「断开」，等待画面时也能断开；桌面窗口栏新增设置按钮。
- Android 手机和 TV 首页会提示新版本，并修复用鼠标裁剪后播放控件不自动隐藏的问题。

### English

- Mirroring now recovers from video decode errors instead of stopping.
- Added Disconnect to the playback toolbar and while waiting for the first frame, and a Settings button to the desktop window bar.
- Android phones and TVs now show available updates on the home screen, and playback controls hide again after cropping with the mouse.

## 0.1.8

### 中文

- 修复投屏时音量跳到最大的问题，首次启动默认 50%，并记住上次调好的音量。
- 修复 Windows 日志中的文件路径导致接收状态同步失败的问题。
- 改进 TV 遥控器焦点与裁剪操作，修复裁剪后播放控件不自动隐藏的问题。
- 优化设置、日志和更新界面，更新说明跟随应用语言显示。

### English

- Fixed volume jumping to maximum when casting, with a 50% default on first launch and the last volume remembered.
- Fixed Windows file paths in logs breaking receiver state synchronization.
- Improved TV remote focus and cropping controls, and fixed playback controls staying visible after cropping.
- Refined settings, logs, and update screens, with release notes shown in the app's language.

## 0.1.6

### 中文

- Windows 新增应用内更新，可自动检查、查看说明、下载及安装重启；更新元数据使用 Ed25519 签名，安装前校验文件完整性。旧版需先手动安装一次本版；仅配置公钥的正式安装版启用，便携版仍需手动更新，安装包尚无 Authenticode 签名。
- Android 手机和 TV 新增应用内更新，支持查看说明、下载、取消和系统安装确认；首次安装更新可能需要在系统设置中允许安装未知应用，安装会中断接收。
- 各平台新增视频裁剪，支持自由比例、16:9、拖动、键盘及 TV 遥控器操作，可预览后应用；裁剪仅保留在当前连接内，来源宽高比变化时重置，桌面窗口随应用后的裁剪调整。
- 改进播放控制和菜单：鼠标悬停、键盘焦点和打开菜单时保持控件可见；TV 返回键先关闭菜单，断开操作移至「更多」菜单。
- 修复 Windows 窗口初始化死锁及设置、标题栏、托盘缺失更新入口的问题；桌面断开投屏后在当前屏幕恢复窗口尺寸，避免恢复到原屏幕位置，并修复 macOS 全屏结束后尺寸控制未恢复导致断开时无法退出全屏的问题。
- 修复音频连接结束后的输出清理及 Apple 平台休眠后的音频时钟换算，并改进 macOS 视频显示停滞后的恢复。

### English

- Added in-app updates on Windows with automatic checks, release notes, downloads, and installation with restart. Ed25519-signed metadata and installer integrity checks protect updates. Older versions require one manual installation of this release. Updates require a configured installed Release build; portable copies remain manual, and Setup is not Authenticode-signed.
- Added in-app updates on Android phones and TVs with release notes, downloads, cancellation, and system installation confirmation. The first update may require allowing installation from this app in system settings. Installation interrupts reception.
- Added video cropping on all platforms with free and 16:9 ratios, dragging, keyboard and TV remote controls, and preview before applying. Crops last for the current connection and reset when the source aspect ratio changes. Desktop windows resize to the applied crop.
- Improved playback controls and menus: hovering, keyboard focus, and open menus keep controls visible. TV Back closes an open menu first, and Disconnect is now in the More menu.
- Fixed a Windows window initialization deadlock and missing update entries in Settings, the window bar, and the tray. Desktop windows restore their size on the current display after disconnection instead of returning to the previous display position. Fixed sizing remaining suspended after macOS fullscreen entry, which prevented a later disconnection from exiting fullscreen.
- Fixed audio output cleanup when the audio connection ends and audio clock conversion after sleep on Apple platforms, and improved recovery from stalled video display on macOS.

## 0.1.5

### 中文

- macOS 新增应用内更新：默认自动检查，可在设置中手动检查、查看更新说明、下载及安装重启；关闭更新面板后下载继续，投屏中安装前会请求确认。0.1.4 及更早版本需先手动升级一次，其他平台仍需手动更新。
- 各平台新增播放缓冲设置，可选择平台默认值或 40–300 毫秒预设，音视频共用缓冲；设置在等待接收时或当前连接结束后生效。
- macOS 视频改用原生定时显示，改进桌面窗口随画面尺寸及旋转调整的行为，修复 macOS 窗口动画结束时未精确到达目标的问题，并新增原始尺寸和适应屏幕快捷键。
- 改进各平台视频调度，积压时合并已到期画面，减少恢复播放时显示陈旧画面；新增 macOS 和 Android 显示时序诊断。
- macOS、Windows 和 Linux 托盘菜单显示接收名称、连接状态及发送设备，提供接收与断开操作；启用关闭到托盘时，隐藏窗口后继续音视频播放。
- 修复桌面退出时原生回调未及时清理导致的崩溃，以及 Linux 切换播放状态后托盘菜单项失效、退出卡住的问题。

### English

- Added in-app updates on macOS with automatic checks enabled by default, manual checks, release notes, downloads, and installation with restart. Downloads continue after closing the update panel, and installation asks for confirmation during a connection. Versions 0.1.4 and earlier require one manual upgrade first; other platforms still require manual updates.
- Added playback buffer settings on all platforms, offering platform defaults or presets from 40 to 300 ms shared by audio and video. Changes apply while waiting for a connection or after the current connection ends.
- Switched macOS video to native timed display, improved desktop window sizing and rotation behavior, fixed macOS window animations not reaching their exact target on completion, and added Actual Size and Fit to Screen keyboard shortcuts.
- Improved video scheduling on all platforms by coalescing overdue frames during backlogs to reduce stale pictures when playback recovers. Added display timing diagnostics on macOS and Android.
- Updated macOS, Windows, and Linux tray menus to show the receiver name, connection status, and sender, with reception and disconnect controls. Audio and video continue when the window is hidden with close-to-tray enabled.
- Fixed desktop exit crashes caused by native callbacks remaining registered during shutdown, and Linux tray menu items becoming invalid and shutdown hanging after playback state changes.

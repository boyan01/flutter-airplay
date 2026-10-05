# 应用图标

Android、macOS、Windows、Linux 和 iPhone／iPad 共用象牙白色的屏幕与向上投送三角。背景沿用应用的青绿色，
从 `#32958A` 渐变到 `#124B46`。图形不含文字，便于小尺寸识别。

`receiver_mark.png` 是使用 Codex 内置 imagegen 工具生成的透明原图。
平台导出由 macOS 自带的 Swift、AppKit 和 ImageIO 完成，不需要额外依赖，
也不需要重新调用图像生成服务。导出命令统一见
[开发指南](../../DEVELOPMENT.md#资源与内部脚本)。

脚本输出：

- macOS：`macos/Runner/Assets.xcassets/AppIcon.appiconset/`，16–1024 px，
  带透明外边距、圆角背景和轻微阴影。
- Android：`android/app/src/main/res/mipmap-*/`，五种密度的传统图标，
  以及 108 dp 的透明前景和单色前景。符号宽度为 54 dp，位于 66 dp 安全区域内。
- Android TV：`android/app/src/main/res/drawable-xhdpi/tv_banner.png`，320 × 180 px。
- iPhone／iPad：`ios/Runner/Assets.xcassets/AppIcon.appiconset/`，按现有
  `Contents.json` 导出全部尺寸，包括 iPad 的 76、152、167 px 图标和 1024 px
  商店图标。背景完全不透明，系统负责圆角裁切。
- Windows：`windows/runner/resources/app_icon.ico`，包含 16、24、32、48、64、
  128、256 px 的 PNG 图层，由现有 `Runner.rc` 打包。
- Linux：`linux/icons/tech.soit.flutterairplay.png`，512 px，使用圆角背景。
  GTK 从应用 bundle 加载窗口图标；CMake 同时打包 desktop entry 和 hicolor 图标，
  供桌面环境注册使用。桌面入口的 `Exec` 依赖 `flutter_airplay` 位于 PATH，
  或在安装时改为 bundle 中可执行文件的绝对路径。

Android 自适应图标入口为 `mipmap-anydpi-v26/ic_launcher.xml`，
渐变背景为 `drawable/ic_launcher_background.xml`。背景颜色与脚本中的颜色保持一致。
启动器负责裁切外形；单色前景供支持主题色图标的启动器使用。
规范参考：[Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。

这些资源由平台直接打包，原图无需加入 Flutter 的运行时 assets。
统一的是图案和配色，外边距、圆角和裁切方式按平台适配。
Android 主题色图标以及桌面托盘／菜单栏状态图标使用单色或状态色，
与彩色应用图标用途不同。现有状态图标不由本脚本重新生成。

Linux 和 Windows 托盘使用简化的屏幕与投送三角，按接收状态配色：

| 状态 | 颜色 |
| --- | --- |
| 接收关闭 | 灰色 `#A0A9AE` |
| 等待连接 | 青绿色 `#32958A` |
| 检查、启动、停止，或已连接但尚无媒体播放 | 黄色 `#E4B55E` |
| 视频或音频播放 | 亮绿色 `#20BFA9` |
| 接收异常 | 红色 `#F06A6A` |

Linux 使用 `linux/icons/airplay-*.svg`，由 CMake 打包进 bundle 的 `data/icons/`；
Windows 在 `windows/runner/flutter_window.cpp` 中绘制透明背景的 32 px 图标。
修改托盘配色时，两处颜色和状态映射需保持一致。

## 原始生成提示词

```text
Use case: logo-brand
Asset type: shared foreground symbol for a macOS and Android AirPlay receiver app icon.
Primary request: create one refined, highly legible screen-casting emblem: a wide softly rounded rectangular screen outline with the center of its bottom edge open, and one upright equilateral triangular receiver arrow pointing upward into that opening.
Style/medium: precision-designed icon with substantial ivory-white strokes, restrained soft ceramic depth and a faint mint highlight. Front-facing and symmetrical, crisp polished edges, no perspective.
Composition/framing: a single centered symbol, approximately 68% of the square canvas width and 56% of its height. Screen above, arrow overlapping the bottom-center opening. Keep generous transparent padding on all sides. The screen interior must be genuinely transparent, as must the exterior background.
Color palette: warm ivory-white foreground, very subtle cool mint edge shading, suitable for placement on deep teal #23786e.
Materials/textures: smooth satin, restrained dimensional highlights; no busy texture, no cast shadow outside the symbol.
Text: none.
Constraints: transparent background and transparent screen interior; no rounded-square tile; no surrounding container; no letters, no Flutter logo, no watermark, no extra wifi waves, no phone, no tiny details. The strokes and triangular arrow must remain readable at a 16-pixel app icon size. Output a square high-resolution PNG foreground asset.
```

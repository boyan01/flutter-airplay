# 应用图标

Android 和 macOS 共用象牙白色的屏幕与向上投送三角。背景沿用应用的青绿色，
从 `#32958A` 渐变到 `#124B46`。图形不含文字，便于小尺寸识别。

`receiver_mark.png` 是使用 Codex 内置 imagegen 工具生成的透明原图。
平台导出由 macOS 自带的 Swift、AppKit 和 ImageIO 完成，不需要额外依赖，
也不需要重新调用图像生成服务。在仓库根目录运行：

```sh
swift scripts/generate_icons.swift
```

脚本输出：

- macOS：`macos/Runner/Assets.xcassets/AppIcon.appiconset/`，16–1024 px，
  带透明外边距、圆角背景和轻微阴影。
- Android：`android/app/src/main/res/mipmap-*/`，五种密度的传统图标，
  以及 108 dp 的透明前景和单色前景。符号宽度为 54 dp，位于 66 dp 安全区域内。
- Android TV：`android/app/src/main/res/drawable-xhdpi/tv_banner.png`，320 × 180 px。

Android 自适应图标入口为 `mipmap-anydpi-v26/ic_launcher.xml`，
渐变背景为 `drawable/ic_launcher_background.xml`。背景颜色与脚本中的颜色保持一致。
启动器负责裁切外形；单色前景供支持主题色图标的启动器使用。
规范参考：[Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。

这些资源由平台直接打包，原图无需加入 Flutter 的运行时 assets。

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

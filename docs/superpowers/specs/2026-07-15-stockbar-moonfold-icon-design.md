# StockBar 月相折纸图标设计

## 目标

将 StockBar 的 Dock 应用图标和菜单栏图标改为统一的「月相折纸」视觉：抽象、安静、非金融语义，避免任何 K 线、曲线、涨跌、货币或股票意象。

## 视觉方案

- Dock 图标：1024×1024 的 macOS 圆角方形，深靛蓝到蓝紫的低饱和渐变背景；中央使用两片相交的柔和弧面，形成抽象月牙／折纸轮廓，并在交点加一颗极小暖白光点。
- 菜单栏图标：同一月牙／折纸轮廓的单色 SF Symbol 模板图；保持 14pt regular 字重和 `isTemplate = true`，由 macOS 按深浅菜单栏自动着色。
- 不出现文字、数值、网格、箭头、行情线、蜡烛图或货币符号。

## 资源与实现边界

1. 以 `assets/icon/icon.svg` 为唯一可编辑源，替换其现有金融图形。
2. 运行既有 `assets/icon/build.sh` 生成完整 `AppIcon.iconset` 与 `AppIcon.icns`；打包脚本继续把该 `.icns` 复制进应用资源，无须改动资源加载路径。
3. `StatusItemController.makeMenuBarIcon()` 改用与月相折纸相近的系统单色符号；不引入自定义位图，以保持菜单栏在各显示模式下的清晰度。
4. 不改动行情、持仓、Helper 或其他应用功能。

## 验证

1. 检查 SVG 中不再包含蜡烛、趋势线或金融配色的图形元素。
2. 重新生成 `.icns`，确认 iconset 含 16–1024px 全部规范尺寸。
3. 运行 `swift build -c release` 与 `bash scripts/build.sh release`。
4. 通过 `codesign --verify --deep --strict --verbose=2 StockBar.app` 验证成品包。

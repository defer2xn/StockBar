# StockBar Moonfold Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace StockBar's finance-themed app icon and `sparkles` menu bar icon with one coherent, abstract moonfold identity.

**Architecture:** Keep `assets/icon/icon.svg` as the editable app-icon source and regenerate the existing macOS iconset/ICNS artifacts through `assets/icon/build.sh`. Use an SF Symbol moon-phase glyph as the monochrome menu bar counterpart so AppKit continues to handle light/dark appearance automatically.

**Tech Stack:** SVG, librsvg (`rsvg-convert`), macOS `iconutil`, Swift/AppKit, Swift Package Manager, codesign

---

## File map

- Modify `assets/icon/icon.svg`: canonical full-color moonfold app icon.
- Regenerate `assets/icon/AppIcon.iconset/*.png`: standard 16–1024px raster assets.
- Regenerate `assets/icon/AppIcon.icns`: packaged macOS app icon.
- Regenerate `assets/icon/preview.png`: 1024px review image.
- Modify `Sources/StockBar/StatusItemController.swift`: monochrome moon-phase menu bar glyph.
- Regenerate `StockBar.app`: release bundle used for local launch and final verification.

### Task 1: Replace the app icon artwork

**Files:**
- Modify: `assets/icon/icon.svg`
- Regenerate: `assets/icon/AppIcon.iconset/*.png`
- Regenerate: `assets/icon/AppIcon.icns`
- Regenerate: `assets/icon/preview.png`

- [ ] **Step 1: Prove the current source still contains finance imagery**

Run:

```bash
rg -n 'Candle|candle|上升曲线|细网格|redCandle|greenCandle' assets/icon/icon.svg
```

Expected: matches are printed, demonstrating that the old icon violates the new design constraint.

- [ ] **Step 2: Replace the SVG with the approved moonfold artwork**

Use a 1024×1024 macOS squircle with a low-saturation indigo/violet background. Construct the central mark from a crescent mask, a translucent folded facet, and one warm-white point of light. The final source must contain no text, grid, chart, arrow, candle, currency, or red/green trading pair.

The central structure must follow this composition:

```xml
<mask id="crescentMask">
  <rect width="1024" height="1024" fill="black"/>
  <circle cx="478" cy="500" r="252" fill="white"/>
  <circle cx="590" cy="414" r="224" fill="black"/>
</mask>
<g mask="url(#crescentMask)">
  <circle cx="478" cy="500" r="252" fill="url(#moonFace)"/>
  <path d="M302 651 C430 615 543 552 654 414 C609 587 502 708 365 745 Z"
        fill="url(#foldFace)"/>
</g>
<circle cx="675" cy="330" r="15" fill="#FFF3D6"/>
```

- [ ] **Step 3: Validate the SVG and absence of finance markers**

Run:

```bash
xmllint --noout assets/icon/icon.svg
! rg -n 'Candle|candle|上升曲线|细网格|redCandle|greenCandle|chart|stock|currency' assets/icon/icon.svg
```

Expected: `xmllint` exits 0 and the negative search exits 0 without output.

- [ ] **Step 4: Regenerate all icon artifacts**

Run:

```bash
bash assets/icon/build.sh
rsvg-convert -w 1024 -h 1024 assets/icon/icon.svg -o assets/icon/preview.png
```

Expected: `assets/icon/build.sh` prints the generated `AppIcon.icns` path, and `preview.png` is rewritten.

- [ ] **Step 5: Verify the generated dimensions and ICNS**

Run:

```bash
file assets/icon/AppIcon.icns assets/icon/preview.png assets/icon/AppIcon.iconset/*.png
```

Expected: `AppIcon.icns` is reported as a macOS icon; PNG entries cover 16, 32, 64, 128, 256, 512, and 1024 pixels.

- [ ] **Step 6: Commit the app icon assets**

```bash
git add assets/icon/icon.svg assets/icon/preview.png assets/icon/AppIcon.icns assets/icon/AppIcon.iconset
git commit -m "icon: 换成月相折纸应用图标"
```

### Task 2: Match the menu bar icon

**Files:**
- Modify: `Sources/StockBar/StatusItemController.swift`

- [ ] **Step 1: Prove the current source still selects `sparkles`**

Run:

```bash
rg -n 'systemSymbolName: "sparkles"' Sources/StockBar/StatusItemController.swift
```

Expected: one match is printed.

- [ ] **Step 2: Replace the menu bar symbol and description**

Keep the existing 14pt regular configuration and template behavior, but change the implementation to:

```swift
/// 月相折纸图标，与 App 图标保持同一轮廓语义；单色模板图随明暗模式自动反色
private static func makeMenuBarIcon() -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let symbol = NSImage(
        systemSymbolName: "moonphase.first.quarter.inverse",
        accessibilityDescription: "StockBar"
    )?.withSymbolConfiguration(config)
    symbol?.isTemplate = true
    return symbol ?? NSImage()
}
```

- [ ] **Step 3: Verify the intended symbol is present and the old one is absent**

Run:

```bash
rg -n 'moonphase\.first\.quarter\.inverse|isTemplate = true' Sources/StockBar/StatusItemController.swift
! rg -n 'systemSymbolName: "sparkles"' Sources/StockBar/StatusItemController.swift
```

Expected: the moon-phase symbol and template assignment are printed; the negative search exits 0.

- [ ] **Step 4: Build the Swift target**

Run:

```bash
swift build -c release
```

Expected: build completes successfully with no Swift compiler error.

- [ ] **Step 5: Commit the menu bar change**

```bash
git add Sources/StockBar/StatusItemController.swift
git commit -m "menubar: 换成月相折纸图标"
```

### Task 3: Package and verify the finished app

**Files:**
- Regenerate: `StockBar.app`

- [ ] **Step 1: Assemble the signed release bundle**

Run:

```bash
bash scripts/build.sh release
```

Expected: the script prints `done: /Users/wepie/github/stock-bar/StockBar.app`.

- [ ] **Step 2: Verify the packaged icon is the regenerated icon**

Run:

```bash
cmp assets/icon/AppIcon.icns StockBar.app/Contents/Resources/AppIcon.icns
```

Expected: exits 0 with no output.

- [ ] **Step 3: Verify code signing and repository hygiene**

Run:

```bash
codesign --verify --deep --strict --verbose=2 StockBar.app
git diff --check
git status --short
```

Expected: codesign reports `valid on disk` and `satisfies its Designated Requirement`; diff check exits 0; status contains only the deliberately regenerated bundle if it is tracked.

- [ ] **Step 4: Launch the rebuilt app for visual inspection**

Run:

```bash
open StockBar.app
```

Expected: Dock/Finder shows the moonfold app icon, and the menu bar shows the matching monochrome quarter-moon glyph in both light and dark appearance.

- [ ] **Step 5: Record any tracked bundle update**

If `git status --short StockBar.app` reports tracked changes, commit only that bundle:

```bash
git add StockBar.app
git commit -m "build: 更新月相折纸应用包"
```

If the bundle is ignored or unchanged in Git, do not create an empty commit.

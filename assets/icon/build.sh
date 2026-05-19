#!/usr/bin/env bash
# 从 icon.svg 生成所有尺寸 PNG 并编译为 AppIcon.icns
# 用法: bash assets/icon/build.sh
set -euo pipefail

cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert (brew install librsvg)"; exit 1; }
command -v iconutil    >/dev/null || { echo "需要 iconutil (Xcode CLT)"; exit 1; }

ICONSET=AppIcon.iconset
rm -rf "$ICONSET" AppIcon.icns
mkdir -p "$ICONSET"

generate() {
    local px=$1; local label=$2
    rsvg-convert -w "$px" -h "$px" icon.svg -o "$ICONSET/icon_${label}.png"
}
generate 16   16x16
generate 32   16x16@2x
generate 32   32x32
generate 64   32x32@2x
generate 128  128x128
generate 256  128x128@2x
generate 256  256x256
generate 512  256x256@2x
generate 512  512x512
generate 1024 512x512@2x

iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "→ $(pwd)/AppIcon.icns"

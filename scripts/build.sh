#!/usr/bin/env bash
# 构建 StockBar.app 并打包成 .app bundle
# 用法：bash scripts/build.sh [debug|release]
# 输出：./StockBar.app

set -euo pipefail

CONFIG="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo ">>> swift build --configuration $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="StockBar.app"

echo ">>> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH/StockBar" "$APP/Contents/MacOS/StockBar"
cp "Sources/StockBar/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon
if [ -f "assets/icon/AppIcon.icns" ]; then
    cp "assets/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "⚠️  assets/icon/AppIcon.icns missing —— 跑 bash assets/icon/build.sh 重新生成"
fi

# 拷贝 Python helper 所有源文件 + requirements (排除 venv / pycache)
mkdir -p "$APP/Contents/Resources/helper"
cp helper/*.py helper/requirements.txt "$APP/Contents/Resources/helper/"

# 必要：ad-hoc 签名让 macOS 接受未公证的二进制
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "done: $PROJECT_DIR/$APP"
echo "运行: open $APP"
echo "安装到 /Applications: mv $APP /Applications/"

#!/usr/bin/env bash
# build-app.sh —— 构建 release binary + 打包成 macOS .app bundle
#
# 输出：build/WindsurfSwitcher.app（可直接拖到 /Applications）
#
# 用法：
#   bash scripts/build-app.sh           # release 构建 + bundle
#   bash scripts/build-app.sh debug     # 用 .build/debug 的二进制（开发期快速 bundle）
#
# 默认不签名，本地安装使用足够。如需 codesign：
#   codesign --force --deep --sign "Developer ID Application: ..." build/WindsurfSwitcher.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="WindsurfSwitcher"
BUNDLE_ID="com.windsurfswitcher.native"
APP_DIR="build/$APP_NAME.app"
ICON_SRC="Resources/AppIcon.icns"

if [[ "$CONFIG" == "release" ]]; then
    echo "==> swift build -c release (universal arm64)"
    swift build -c release --product "$APP_NAME"
    BIN_SRC=".build/release/$APP_NAME"
elif [[ "$CONFIG" == "debug" ]]; then
    echo "==> 复用现有 debug binary"
    swift build --product "$APP_NAME"
    BIN_SRC=".build/debug/$APP_NAME"
else
    echo "❌ 未知配置：$CONFIG（应为 release / debug）"
    exit 1
fi

if [[ ! -x "$BIN_SRC" ]]; then
    echo "❌ binary 不存在：$BIN_SRC"
    exit 1
fi

echo "==> 准备 .app bundle 骨架"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_SRC" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "⚠️  图标资源不存在：$ICON_SRC（可运行 scripts/generate-app-icon.py 生成）"
fi

VERSION="${WSS_VERSION:-0.1.0}"
BUILD="${WSS_BUILD:-$(date +%s)}"

echo "==> 生成 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Windsurf Switcher</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Open source · MIT</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "==> 完成：$APP_DIR"
echo "    版本：$VERSION ($BUILD)"
echo "    bundle id：$BUNDLE_ID"
echo "    LSUIElement=true（无 dock 图标，仅菜单栏）"
echo
echo "下一步："
echo "  open $APP_DIR                           # 直接启动"
echo "  bash scripts/build-dmg.sh               # 打 DMG"
echo "  cp -r $APP_DIR /Applications/           # 安装"

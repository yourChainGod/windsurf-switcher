#!/usr/bin/env bash
# build-dmg.sh —— 把 build/WindsurfSwitcher.app 打成 DMG
#
# 不依赖 create-dmg；纯 hdiutil + sparseimage 流程。
# 输出：build/WindsurfSwitcher-<version>.dmg
#
# 前置：先跑 scripts/build-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="WindsurfSwitcher"
APP_DIR="build/$APP_NAME.app"
VERSION="${WSS_VERSION:-0.2.0}"
DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="build/$DMG_NAME.dmg"
STAGING="build/.dmg-staging"

if [[ ! -d "$APP_DIR" ]]; then
    echo "❌ $APP_DIR 不存在；请先跑 scripts/build-app.sh"
    exit 1
fi

echo "==> 准备 staging：$STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# README 让用户知道怎么装
cat > "$STAGING/README.txt" <<'EOF'
Windsurf Switcher — 安装

1. 把 WindsurfSwitcher.app 拖到旁边的 Applications 快捷方式
2. 首次启动 macOS 可能拦截（"无法打开"）—— 右键 → 打开 一次即可
3. 点击菜单栏右侧的 风扇图标 ⌬ 弹出窗口
4. Settings → wrapper 一键安装两个 windsurf app（需要管理员密码）

文档 / 故障排查：见仓库 README.md
EOF

echo "==> 计算大小"
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))

echo "==> hdiutil create ($SIZE_MB MB)"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -size "${SIZE_MB}m" \
    "$DMG_PATH" >/dev/null

echo "==> 清理"
rm -rf "$STAGING"

echo "==> 完成：$DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo
echo "如需签名 + notarize："
echo "  codesign --force --deep --sign 'Developer ID Application: <YOUR NAME>' $APP_DIR"
echo "  xcrun notarytool submit $DMG_PATH --apple-id ... --team-id ... --password ... --wait"
echo "  xcrun stapler staple $DMG_PATH"

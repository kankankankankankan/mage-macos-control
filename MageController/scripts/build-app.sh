#!/bin/bash
# 构建 MAGE Controller.app（菜单栏 App + mage-helper 拦截守护进程）
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/MAGE Controller.app"
BUILD=.build/release
HELPER="$APP/Contents/MacOS/mage-helper"

swift build -c release

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS"

cp "$BUILD/MageControllerApp" "$APP/Contents/MacOS/MAGE Controller"
cp "$BUILD/mage-helper"       "$HELPER"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/AppIcon.icns"       "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.fiio.mage-controller</string>
    <key>CFBundleName</key>
    <string>MAGE Controller</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MAGE Controller</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

test -x "$HELPER" || { echo "helper 缺失或不可执行: $HELPER" >&2; exit 1; }

# 固定身份签名（MAGE Dev Signing 自签名证书）：adhoc 每次构建哈希都变，
# macOS 会当成新应用反复弹权限框；固定证书后辅助功能/输入监控授权跨构建保留。
KEYCHAIN="$HOME/Library/Keychains/mage-dev.keychain-db"
security unlock-keychain -p magedev "$KEYCHAIN" 2>/dev/null || true
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "MAGE Dev Signing"; then
  codesign --force --sign "MAGE Dev Signing" --keychain "$KEYCHAIN" "$HELPER"
  codesign --force --sign "MAGE Dev Signing" --keychain "$KEYCHAIN" "$APP"
else
  echo "警告: 未找到 MAGE Dev Signing 证书，回退 adhoc 签名（权限将重新弹框）" >&2
  codesign --force --sign - "$HELPER" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "已生成: $APP"
echo "helper: $HELPER"

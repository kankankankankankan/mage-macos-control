#!/bin/bash
# 构建 MAGE Controller.app（菜单栏 App + mage-helper 拦截守护进程）
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/MAGE Controller.app"
BUILD=.build/release

swift build -c release

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS"

cp "$BUILD/MageControllerApp" "$APP/Contents/MacOS/MAGE Controller"
cp "$BUILD/mage-helper"       "$APP/Contents/MacOS/mage-helper"

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
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成: $APP"

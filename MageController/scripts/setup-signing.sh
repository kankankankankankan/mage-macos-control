#!/bin/bash
# 一次性生成本机开发签名证书 MAGE Dev Signing。
# 为什么需要：adhoc 签名每次构建哈希都变，macOS 会当成新应用，
# 「辅助功能/输入监控」权限每次都要重授。固定证书后授权跨构建保留。
# 用法：bash scripts/setup-signing.sh   （只需运行一次）
set -e
KEYCHAIN="$HOME/Library/Keychains/mage-dev.keychain-db"
PW="magedev"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "MAGE Dev Signing"; then
  echo "证书已存在，无需重复创建"
  exit 0
fi

# 1. 创建专用钥匙串（与登录钥匙串隔离，避免误改系统项）
security create-keychain -p "$PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"   # 6 小时自动锁定
security unlock-keychain -p "$PW" "$KEYCHAIN"

# 2. 生成自签名证书（代码签名用途，有效期 10 年）
#    交互提示时直接回车（使用默认参数）即可
security req -a -keychain "$KEYCHAIN" \
  -s "/C=CN/CN=MAGE Dev Signing" \
  -k "$KEYCHAIN" \
  -r codesigning -v 3650

# 3. 允许 codesign 在非交互场景下使用钥匙串（否则命令行构建会弹密码框）
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KEYCHAIN"

echo "完成。证书："
security find-identity -v -p codesigning "$KEYCHAIN"
echo "现在运行 bash scripts/build-app.sh 即会用该证书签名。"
echo "首次运行 App 时在 系统设置 → 隐私与安全性 → 辅助功能/输入监控 里允许一次即可。"

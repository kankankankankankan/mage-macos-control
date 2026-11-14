#!/bin/bash
# 一次性生成本机开发签名证书 MAGE Dev Signing。
#
# 为什么需要它：
#   adhoc 签名每次构建哈希都变，macOS 会当成新应用，「辅助功能/输入监控」
#   权限每次构建都要重授。用固定证书签名后授权跨构建保留。
#
# 用法：bash scripts/setup-signing.sh    （只需运行一次）
#
# 过程会弹一次系统授权框（把证书标记为代码签名信任，需要管理员密码）。
# 已有 Apple 开发者证书的开发者无需运行本脚本，直接把 build-app.sh 里的
# 签名身份换成自己的证书名即可。
set -e
KEYCHAIN="$HOME/Library/Keychains/mage-dev.keychain-db"
PW="magedev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; security delete-keychain "$TMP/k.keychain-db" 2>/dev/null || true' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "MAGE Dev Signing"; then
  echo "证书 MAGE Dev Signing 已存在，无需重复创建。"
  exit 0
fi

echo "1/5 创建专用钥匙串（mage-dev.keychain-db，与系统钥匙串隔离）…"
security create-keychain -p "$PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"   # 6 小时自动锁定
security unlock-keychain -p "$PW" "$KEYCHAIN"

echo "2/5 生成自签名证书（RSA 2048，有效期 10 年，代码签名用途）…"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=MAGE Dev Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

echo "3/5 导入钥匙串…"
openssl pkcs12 -export -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -password "pass:$PW" -name "MAGE Dev Signing" 2>/dev/null
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign

echo "4/5 标记为代码签名信任（系统会弹一次授权框，输入开机密码）…"
security add-trusted-cert -k "$KEYCHAIN" -p codeSign "$TMP/cert.pem"

echo "5/5 允许 codesign 免密使用钥匙串…"
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KEYCHAIN" >/dev/null

echo
echo "完成："
security find-identity -v -p codesigning "$KEYCHAIN" | tail -2
echo
echo "之后运行 bash scripts/build-app.sh 即自动用该证书签名。"
echo "首次运行 App 时，在 系统设置 → 隐私与安全性 → 输入监控 里允许一次即可，"
echo "此后重新构建不再重复弹权限框。"

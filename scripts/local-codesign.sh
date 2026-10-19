#!/usr/bin/env bash
# 用本机固定的自签名证书重签 Debug 构建。
# ad-hoc 签名的指定要求是每次构建都会变的 cdhash，macOS 隐私授权（下载、文稿、桌面等）因此每次重装都失效；
# 换成固定证书后，指定要求变为「包名 + 证书」，授权一次即可长期保留。
# 证书只在登录钥匙串里首次创建一次，不需要信任设置，也不参与任何分发。
set -euo pipefail

APP="${1:?usage: local-codesign.sh path/to/1Agent.app}"
IDENTITY="Ghostty Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "→ creating local code signing certificate “${IDENTITY}” in the login keychain"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # 系统自带的 LibreSSL 生成的 p12，security import 一定能读。
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$IDENTITY" -passout pass:ghostty -out "$work/identity.p12" 2>/dev/null
  security import "$work/identity.p12" -k "$KEYCHAIN" -P ghostty -T /usr/bin/codesign >/dev/null
fi

hash="$(security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" | sed -n 's/^SHA-1 hash: //p' | head -1)"
if [[ -z "$hash" ]]; then
  echo "error: certificate “${IDENTITY}” not found in the login keychain" >&2
  exit 1
fi

for dylib in "$APP"/Contents/MacOS/*.dylib; do
  [[ -e "$dylib" ]] && codesign --force --sign "$hash" --timestamp=none "$dylib"
done
if [[ -x "$APP/Contents/Helpers/oneagent-agent-session" ]]; then
  codesign --force --sign "$hash" --timestamp=none "$APP/Contents/Helpers/oneagent-agent-session"
fi
codesign --force --sign "$hash" --timestamp=none --preserve-metadata=entitlements "$APP"
echo "→ signed with “${IDENTITY}”"

#!/bin/bash
# 先签内部 helper，再签 framework；主应用由调用方最后签名。
set -euo pipefail
app="${1:?app bundle}"
identity="${2:?signing identity}"
framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" ]] || exit 0
timestamp=(--timestamp=none)
if [[ "$identity" == 'Developer ID Application:'* ]]; then timestamp=(--timestamp); fi
for relative in Versions/B/Autoupdate Versions/B/Updater.app Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc; do
    target="$framework/$relative"
    [[ -e "$target" ]] || continue
    codesign --force --sign "$identity" --options runtime "${timestamp[@]}" --preserve-metadata=identifier,entitlements "$target"
done
codesign --force --sign "$identity" --options runtime "${timestamp[@]}" "$framework"

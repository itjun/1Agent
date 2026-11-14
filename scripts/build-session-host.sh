#!/bin/bash
# 后台终端使用同一版本的 Ghostty VT，独立于窗口进程保存屏幕和 PTY。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?session host output path}"
mkdir -p "$(dirname "$destination")"
arch_args=()
for arch in ${ARCHS:-$(uname -m)}; do arch_args+=(-arch "$arch"); done
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror "${arch_args[@]}" -mmacosx-version-min=14.0 \
    -I "$root/build/libghostty/source/include" \
    "$root/Sources/SessionHost/main.c" "$root/build/libghostty/libghostty-vt.a" \
    -o "$destination"
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$destination"
fi

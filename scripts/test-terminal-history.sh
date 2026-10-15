#!/bin/bash
set -euo pipefail
history_root="$(cd "$(dirname "$0")/.." && pwd)"
history_temp="$(mktemp -d /tmp/oneagent-history-tests.XXXXXX)"
trap 'rm -rf "$history_temp"' EXIT
history_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
history_swift="$history_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
history_sdk="$history_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ ! -x "$history_swift" ]]; then history_swift="$(xcrun --find swiftc)"; fi
if [[ ! -d "$history_sdk" ]]; then history_sdk="$(xcrun --sdk macosx --show-sdk-path)"; fi
"$history_swift" -sdk "$history_sdk" -o "$history_temp/model-test" \
  "$history_root/Sources/GooseAgent/TerminalHistory.swift" "$history_root/Tests/TerminalHistoryTests.swift"
"$history_temp/model-test"
"$history_swift" -sdk "$history_sdk" -o "$history_temp/view-test" \
  "$history_root/Sources/GooseAgent/TerminalSettings.swift" \
  "$history_root/Sources/GooseAgent/TerminalHistory.swift" \
  "$history_root/Sources/GooseAgent/TerminalHistoryView.swift" \
  "$history_root/Sources/GooseAgent/Theme.swift" \
  "$history_root/Tests/TerminalHistoryViewTests.swift"
"$history_temp/view-test"
history_products="${ONEAGENT_HISTORY_PRODUCTS:-$history_root/build/DerivedData.noindex/Build/Products/Debug}"
if [[ ! -f "$history_products/GhosttyTerminal.o" ]]; then
  echo 'SKIP terminal history engine: build the app dependencies first (no shell or SSH is launched by the test).'
  exit 0
fi
ln -s "$history_products/GhosttyKit_GhosttyTerminal.bundle" "$history_temp/GhosttyKit_GhosttyTerminal.bundle"
"$history_swift" -parse-as-library -target "$(uname -m)-apple-macosx14.0" -sdk "$history_sdk" \
  -I "$history_products" -I "$history_products/include/libghostty" \
  "$history_root/Sources/GooseAgent/TerminalHistory.swift" \
  "$history_root/Tests/TerminalHistoryEngineTests.swift" \
  "$history_products/GhosttyTerminal.o" "$history_products/GhosttyKit.o" \
  "$history_products/MSDisplayLink.o" "$history_products/libghostty.a" \
  -lc++ -framework Carbon -o "$history_temp/engine-test"
"$history_temp/engine-test"

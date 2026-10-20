#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-terminal-windows.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/TerminalWindowsTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
cat > "$test_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.itjun.terminal-window-tests</string>
<key>CFBundleName</key><string>TerminalWindowsTests</string>
<key>CFBundleExecutable</key><string>terminal-windows-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAppleScriptEnabled</key><true/>
<key>OSAScriptingDefinition</key><string>1Agent.sdef</string>
</dict></plist>
PLIST
test_executable="$test_bundle/MacOS/terminal-windows-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$repo_dir/build/TerminalWindowsModuleCache.noindex" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/TerminalWindowsTests.swift" "$repo_dir/Tests/TerminalCompatibilityTests.swift" \
    -o "$test_executable"
if [[ "${2:-}" == *compatibility ]]; then
    # Real shell runtimes use their system helpers. HOME/XDG are isolated; no network.
    /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network-outbound (remote ip "*:*")) (deny network-inbound (local ip "*:*")) (deny network-bind (local ip "*:*"))' \
        /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" ONEAGENT_TEST_HOME="$test_dir/home" "$test_executable" "${@:2}"
    exit $?
fi
# Real terminal surfaces run only cat, with no login configuration, shell or SSH.
/usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/bin/cat\") (literal \"/usr/bin/env\") (literal \"$test_executable\"))" \
    /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" ONEAGENT_TEST_HOME="$test_dir/home" "$test_executable"

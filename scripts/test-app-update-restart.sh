#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-update-restart.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
bundle="$test_dir/UpdateRestartTests.app/Contents"
mkdir -p "$bundle/MacOS" "$test_dir/home"
cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.itjun.update-restart-tests</string>
<key>CFBundleName</key><string>UpdateRestartTests</string>
<key>CFBundleExecutable</key><string>update-restart-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.3</string>
</dict></plist>
PLIST
developer_dir=/Applications/Xcode.app/Contents/Developer
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$test_dir/module-cache" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/AppUpdateRestartTests.swift" \
    -o "$bundle/MacOS/update-restart-tests"
/usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/usr/bin/env\") (literal \"$bundle/MacOS/update-restart-tests\"))" \
    /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" "$bundle/MacOS/update-restart-tests"

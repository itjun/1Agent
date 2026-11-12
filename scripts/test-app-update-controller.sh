#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-app-update.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/AppUpdateControllerTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
cat > "$test_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.itjun.app-update-tests</string>
<key>CFBundleName</key><string>AppUpdateControllerTests</string>
<key>CFBundleExecutable</key><string>app-update-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
</dict></plist>
PLIST
test_executable="$test_bundle/MacOS/app-update-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$repo_dir/build/AppUpdateControllerModuleCache.noindex" \
    -F "$products_dir" -Xlinker -rpath -Xlinker "$products_dir/1Agent.app/Contents/Frameworks" -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/AppUpdateControllerTests.swift" \
    -o "$test_executable"
/usr/bin/env CFFIXED_USER_HOME="$test_dir/home" "$test_executable"

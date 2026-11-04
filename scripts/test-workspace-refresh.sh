#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="$repo_dir/build/DerivedData.noindex/Build/Products/Debug"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-refresh-runner.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/home" "$test_dir/RefreshTests.app/Contents/MacOS"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_dir/RefreshTests.app/Contents/Resources"
swift_compiler=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
sdk_dir="$(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/WorkspaceRefreshTests.swift" \
    -o "$test_dir/RefreshTests.app/Contents/MacOS/tests"
CFFIXED_USER_HOME="$test_dir/home" "$test_dir/RefreshTests.app/Contents/MacOS/tests" -AppleLanguages '(en)'

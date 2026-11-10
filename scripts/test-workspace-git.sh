#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="$repo_dir/build/DerivedData.noindex/Build/Products/Debug"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-git-runner.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
# 原生改动列表回归需要应用内的文件图标与本地化资源。
test_bundle="$test_dir/WorkspaceGitTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/tests"
swift_compiler=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
sdk_dir="$(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/WorkspaceGitTests.swift" -o "$test_executable"
CFFIXED_USER_HOME="$test_dir/home" "$test_executable" "$@"

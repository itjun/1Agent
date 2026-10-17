#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-restoration.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/TerminalRestorationTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/terminal-restoration-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$test_dir/module-cache" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/TerminalRestorationTests.swift" \
    -o "$test_executable"
# Isolated native terminals may run only cat; no login shell or SSH connection is opened.
/usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/bin/cat\")) (allow process-exec (literal \"/usr/bin/env\") (literal \"$test_executable\"))" \
    /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" "$test_executable"

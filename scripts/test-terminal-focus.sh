#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/Natty.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/natty-terminal-focus.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/TerminalFocusTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/Natty.app/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/terminal-focus-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$test_dir/module-cache" \
    -F "$products_dir" -Xlinker -rpath -Xlinker "$products_dir/Natty.app/Contents/Frameworks" -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/Natty.debug.dylib" "$repo_dir/Tests/TerminalFocusTests.swift" \
    -o "$test_executable"
# Native responder tests never need a shell or SSH, and must not load real saved settings.
for attempt in 1 2 3; do
    status=0
    /usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/usr/bin/env\") (literal \"$test_executable\"))" \
        /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" NATTY_TEST_HOME="$test_dir/home" "$test_executable" "${@:2}" || status=$?
    if [ "$status" -eq 0 ]; then exit 0; fi
    # 只重跑真实前台切换造成的环境中断；产品断言失败不能重试成通过。
    if [ "$status" -ne 75 ]; then exit "$status"; fi
    if [ "$attempt" -eq 3 ]; then
        echo "焦点测试连续三轮被其他应用中断，未通过；请在桌面空闲时重跑。" >&2
        exit 75
    fi
    echo "焦点测试第 $attempt 轮被前台切换中断，将从头重跑全部断言。" >&2
done

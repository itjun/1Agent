#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
app_bundle="${ONEAGENT_TEST_APP:-$products_dir/1Agent.app}"
dylib_dir="$app_bundle/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-modal-appearance.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/ModalAppearanceTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$app_bundle/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/modal-appearance-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$repo_dir/build/ModalAppearanceModuleCache.noindex" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/ModalAppearanceTests.swift" \
    -o "$test_executable"
# Render production dialogs and exercise live light/dark changes without user data or processes.
test_args=()
if [[ -n "${ONEAGENT_TEST_LANGUAGE:-}" ]]; then
    test_args=(-AppleLanguages "($ONEAGENT_TEST_LANGUAGE)")
fi
/usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/usr/bin/env\") (literal \"$test_executable\"))" \
    /usr/bin/env CFFIXED_USER_HOME="$test_dir/home" ONEAGENT_TEST_HOME="$test_dir/home" "$test_executable" "${test_args[@]}"

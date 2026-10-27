#!/bin/bash
set -euo pipefail

# Uses an existing Debug build; does not build, install, launch, or restart 1Agent.
# The temporary harness mounts the production RootView without production terminal surfaces.
# Assertions cover the independent file page, explicit cwd reveal, host-only browsing,
# session identity preservation and the hidden-terminal focus guard.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-files-routing.XXXXXX)"
test_bundle="$test_dir/FilesRoutingTests.app/Contents"
test_executable="$test_bundle/MacOS/files-workspace-routing-tests"
trap 'rm -rf "$test_dir"' EXIT

if [[ ! -f "$dylib_dir/1Agent.debug.dylib" ]]; then
    echo "Missing Debug build: run the normal application build first." >&2
    exit 1
fi
if [[ ! -s "$repo_dir/Tests/FilesWorkspaceRoutingTests.swift" ]]; then
    echo "Missing or empty FilesWorkspaceRoutingTests.swift; refusing to launch the application entry point." >&2
    exit 1
fi

developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$test_dir/home" "$test_dir/home/local-a" "$test_dir/home/local-b"
mkdir -p "$test_bundle/MacOS"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
/usr/bin/clang "$repo_dir/Tests/fixtures/file-workspace-remote.c" -o "$test_dir/remote-fixture"
/usr/bin/clang -dynamiclib "$repo_dir/Tests/fixtures/file-workspace-process-guard.c" -o "$test_dir/process-guard.dylib"

"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$test_dir/module-cache" \
    -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/FilesWorkspaceRoutingTests.swift" \
    -o "$test_executable"

# An independent sandbox denies SSH/network and the real .ssh directory even if interposition fails.
sandbox_profile="(version 1) (allow default) (deny network*) (deny process-exec)\
 (allow process-exec (literal \"/usr/bin/env\") (literal \"/usr/bin/printf\")\
 (literal \"$test_executable\") (literal \"$test_dir/remote-fixture\"))\
 (deny file-read* (subpath \"$HOME/.ssh\"))"
/usr/bin/sandbox-exec -p "$sandbox_profile" /usr/bin/env -u SSH_AUTH_SOCK -u SSH_AGENT_PID \
    CFFIXED_USER_HOME="$test_dir/home" ZDOTDIR="$test_dir/home" \
    DYLD_INSERT_LIBRARIES="$test_dir/process-guard.dylib" \
    ONEAGENT_TEST_HOME="$test_dir/home" ONEAGENT_REMOTE_FIXTURE="$test_dir/remote-fixture" \
    "$test_executable"

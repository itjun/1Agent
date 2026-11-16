#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/oneagent-snapshot.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
    -I "$repo_dir/build/libghostty/source/include" \
    "$repo_dir/Tests/SessionSnapshotTests.c" "$repo_dir/build/libghostty/libghostty-vt.a" \
    -o "$test_dir/session-snapshot-tests"
"$test_dir/session-snapshot-tests"

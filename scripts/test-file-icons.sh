#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/oneagent-file-icons.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc -o "$test_directory/test" Sources/GooseAgent/Files/FileTypeIcon.swift Tests/FileIconTests.swift
"$test_directory/test" "$@"

#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/oneagent-upload-check.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc -o "$test_directory/test" \
    Sources/GooseAgent/Theme.swift Sources/GooseAgent/FocusRing.swift Sources/GooseAgent/SheetLayout.swift Sources/GooseAgent/FamilyModal.swift Sources/GooseAgent/FamilyAlert.swift \
    Sources/GooseAgent/Files/FileRules.swift \
    Sources/GooseAgent/Files/FileSystem.swift \
    Sources/GooseAgent/Files/RemoteShell.swift \
    Sources/GooseAgent/Files/FileSafety.swift \
    Sources/GooseAgent/Files/FileTransfer.swift \
    Sources/GooseAgent/Files/TextFile.swift \
    Sources/GooseAgent/Files/UploadCheck.swift \
    Tests/UploadCheckTests.swift
"$test_directory/test"

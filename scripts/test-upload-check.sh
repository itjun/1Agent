#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/natty-upload-check.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc -o "$test_directory/test" \
    Sources/Natty/Theme.swift Sources/Natty/ApplicationIcon.swift Sources/Natty/FocusRing.swift Sources/Natty/SheetLayout.swift Sources/Natty/FamilyModal.swift Sources/Natty/FamilyAlert.swift \
    Sources/Natty/Files/FileRules.swift \
    Sources/Natty/Files/FileSystem.swift \
    Sources/Natty/Files/RemoteShell.swift \
    Sources/Natty/Files/FileSafety.swift \
    Sources/Natty/Files/FileTransfer.swift \
    Sources/Natty/Files/TextFile.swift \
    Sources/Natty/Files/UploadCheck.swift \
    Tests/UploadCheckTests.swift
"$test_directory/test"

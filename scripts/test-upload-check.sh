#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/oneagent-upload-check.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc -o "$test_directory/test" \
    Sources/OneAgent/Theme.swift Sources/OneAgent/ApplicationIcon.swift Sources/OneAgent/FocusRing.swift Sources/OneAgent/SheetLayout.swift Sources/OneAgent/FamilyModal.swift Sources/OneAgent/FamilyAlert.swift \
    Sources/OneAgent/Files/FileRules.swift \
    Sources/OneAgent/Files/FileSystem.swift \
    Sources/OneAgent/Files/RemoteShell.swift \
    Sources/OneAgent/Files/FileSafety.swift \
    Sources/OneAgent/Files/FileTransfer.swift \
    Sources/OneAgent/Files/TextFile.swift \
    Sources/OneAgent/Files/UploadCheck.swift \
    Tests/UploadCheckTests.swift
"$test_directory/test"

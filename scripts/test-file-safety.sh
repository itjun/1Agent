#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/natty-files-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
core=(Sources/Natty/Theme.swift Sources/Natty/ApplicationIcon.swift Sources/Natty/FocusRing.swift Sources/Natty/SheetLayout.swift Sources/Natty/FamilyModal.swift Sources/Natty/FamilyAlert.swift Sources/Natty/Files/FileRules.swift Sources/Natty/Files/FileSystem.swift Sources/Natty/Files/RemoteShell.swift Sources/Natty/Files/FileSafety.swift Sources/Natty/Files/FileTransfer.swift)
swiftc -o "$test_directory/safety" "${core[@]}" Tests/FileSafetyTests.swift
"$test_directory/safety"
swiftc -o "$test_directory/queue" "${core[@]}" Sources/Natty/Files/FileTransferQueue.swift Tests/FileTransferQueueTests.swift
"$test_directory/queue"
swiftc -o "$test_directory/state" Sources/Natty/PaneLayout.swift Sources/Natty/WorkspaceBoard.swift Sources/Natty/Files/TextFile.swift Sources/Natty/Files/FileWorkspaceState.swift Tests/FileWorkspaceStateTests.swift
"$test_directory/state"

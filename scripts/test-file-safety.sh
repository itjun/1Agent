#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/oneagent-files-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
core=(Sources/OneAgent/Theme.swift Sources/OneAgent/ApplicationIcon.swift Sources/OneAgent/FocusRing.swift Sources/OneAgent/SheetLayout.swift Sources/OneAgent/FamilyModal.swift Sources/OneAgent/FamilyAlert.swift Sources/OneAgent/Files/FileRules.swift Sources/OneAgent/Files/FileSystem.swift Sources/OneAgent/Files/RemoteShell.swift Sources/OneAgent/Files/FileSafety.swift Sources/OneAgent/Files/FileTransfer.swift)
swiftc -o "$test_directory/safety" "${core[@]}" Tests/FileSafetyTests.swift
"$test_directory/safety"
swiftc -o "$test_directory/queue" "${core[@]}" Sources/OneAgent/Files/FileTransferQueue.swift Tests/FileTransferQueueTests.swift
"$test_directory/queue"
swiftc -o "$test_directory/state" Sources/OneAgent/PaneLayout.swift Sources/OneAgent/WorkspaceBoard.swift Sources/OneAgent/Files/TextFile.swift Sources/OneAgent/Files/FileWorkspaceState.swift Tests/FileWorkspaceStateTests.swift
"$test_directory/state"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/oneagent-files-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
core=(Sources/GooseAgent/Files/FileRules.swift Sources/GooseAgent/Files/FileSystem.swift Sources/GooseAgent/Files/RemoteShell.swift Sources/GooseAgent/Files/FileSafety.swift Sources/GooseAgent/Files/FileTransfer.swift)
swiftc -o "$test_directory/safety" "${core[@]}" Tests/FileSafetyTests.swift
"$test_directory/safety"
swiftc -o "$test_directory/queue" "${core[@]}" Sources/GooseAgent/Files/FileTransferQueue.swift Tests/FileTransferQueueTests.swift
"$test_directory/queue"
swiftc -o "$test_directory/state" Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Sources/GooseAgent/Files/TextFile.swift Sources/GooseAgent/Files/FileWorkspaceState.swift Tests/FileWorkspaceStateTests.swift
"$test_directory/state"

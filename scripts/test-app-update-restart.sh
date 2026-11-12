#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library "$root/Sources/GooseAgent/AppUpdate.swift" "$root/Tests/AppUpdateTests.swift" -o "$work/tests"
"$work/tests"

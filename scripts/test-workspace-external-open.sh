#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
fixture=$(mktemp -d /private/tmp/natty-external-test.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macosx14.0 -parse-as-library -Xlinker -rpath -Xlinker "$products/Natty.app/Contents/Frameworks" -I "$products" -I "$products/include/libghostty" -Xlinker -rpath -Xlinker "$products/Natty.app/Contents/MacOS" "$products/Natty.app/Contents/MacOS/Natty.debug.dylib" "$repo_dir/Tests/WorkspaceExternalOpenTests.swift" -o "$fixture/external-tests"
"$fixture/external-tests"

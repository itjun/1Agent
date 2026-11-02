#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
products="$repo/build/DerivedData.noindex/Build/Products/Debug"
fixture=$(mktemp -d /private/tmp/oneagent-preview-perf.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/home"
cp "$repo/Resources/AppIcon/macaron-original-mark.png" "$fixture/preview.png"
test_bundle="$fixture/WorkspacePreviewTests.app/Contents"
mkdir -p "$test_bundle/MacOS"
ln -s "$products/1Agent.app/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/perf"
git -C "$fixture" init -q
python3 - "$fixture/fixture.swift" <<'PY'
import sys
open(sys.argv[1],'w').write(''.join(f'let value{i} = "before"\n' for i in range(600)))
PY
git -C "$fixture" add fixture.swift
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qm base
python3 - "$fixture/fixture.swift" <<'PY'
import sys
p=sys.argv[1];s=open(p).read();open(p,'w').write(s.replace('before','after'))
PY
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macosx14.0 -parse-as-library -I "$products" -I "$products/include/libghostty" -Xlinker -rpath -Xlinker "$products/1Agent.app/Contents/MacOS" "$products/1Agent.app/Contents/MacOS/1Agent.debug.dylib" "$repo/Tests/WorkspacePreviewTests.swift" -o "$test_executable"
CFFIXED_USER_HOME="$fixture/home" ONEAGENT_PREVIEW_FIXTURE="$fixture" "$test_executable"

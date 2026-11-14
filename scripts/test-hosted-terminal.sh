#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="$repo_dir/build/DerivedData.noindex/Build/Products/Debug"
test_dir="$(mktemp -d /private/tmp/oneagent-hosted.XXXXXX)"
session_id="$(uuidgen)"
cleanup() {
    python3 - "$session_id" "$test_dir" <<'PY'
import os,socket,sys,pathlib
ids=[sys.argv[1]+'#3']
path=pathlib.Path(sys.argv[2])/'sessions'
if path.exists(): ids+=path.read_text().splitlines()
for session in ids:
    uuid,generation=session.split('#')
    try:
        s=socket.socket(socket.AF_UNIX);s.connect(f'/tmp/1a-term-v1-{os.getuid()}/{uuid}-{generation}/s');s.sendall(b'K\0\0\0\0');s.close()
    except OSError: pass
PY
    rm -rf "$test_dir"
}
trap cleanup EXIT
bundle="$test_dir/HostedTerminalTests.app/Contents"
mkdir -p "$bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$bundle/Resources"
ln -s "$products_dir/1Agent.app/Contents/Helpers" "$bundle/Helpers"
developer_dir=/Applications/Xcode.app/Contents/Developer
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$test_dir/module-cache" -F "$products_dir" \
    -Xlinker -rpath -Xlinker "$products_dir/1Agent.app/Contents/Frameworks" -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$products_dir/1Agent.app/Contents/MacOS" \
    "$products_dir/1Agent.app/Contents/MacOS/1Agent.debug.dylib" "$repo_dir/Tests/HostedTerminalTests.swift" \
    -o "$bundle/MacOS/tests"
for phase in --save --restore --close; do
    CFFIXED_USER_HOME="$test_dir/home" "$bundle/MacOS/tests" "$phase" "$test_dir" "$session_id" "$repo_dir/Tests/session-host-fixture.py" "$(command -v python3)"
done

#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug/1Agent.app}"
test_dir="$(mktemp -d /private/tmp/oneagent-app-icons.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_suite="com.itjun.application-icon-tests.$(uuidgen)"
mkdir -p "$test_dir/home"
fixture_app="$test_dir/IconFixture.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources"
cp /usr/bin/true "$fixture_app/Contents/MacOS/fixture"
cp "$app_bundle/Contents/Resources/AppIcon.icns" "$fixture_app/Contents/Resources/AppIcon.icns"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.itjun.application-icon-fixture</string>
<key>CFBundleExecutable</key><string>fixture</string>
<key>CFBundleName</key><string>IconFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$fixture_app"
codesign --verify --deep --strict "$fixture_app"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -parse-as-library -module-cache-path "$repo_dir/build/AppIconTestsModuleCache.noindex" \
    "$repo_dir/Sources/GooseAgent/ApplicationIcon.swift" "$repo_dir/Tests/ApplicationIconTests.swift" \
    -o "$test_dir/app-icon-tests"
for phase in test save restore; do
    CFFIXED_USER_HOME="$test_dir/home" "$test_dir/app-icon-tests" "$app_bundle" "$test_suite" "$phase" "$fixture_app"
    # Finder customization adds metadata at the bundle root; signed code/resources must stay valid.
    codesign --verify --deep "$fixture_app"
done

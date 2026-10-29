#!/bin/bash
# Build the patched Ghostty engine for both macOS architectures.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
revision=83fb95624b0439ee660c2679b43b38c8b63769cd
archive_sha=7759929eadaddf602d6fd5ad6b3403d854b91b7083975cd984bb525bc8275187
patch="$root/Vendor/libghostty-spm/Patches/ghostty-v1.4.0.patch"
work="$root/build/libghostty"
source_dir="$work/source"
framework="$root/Vendor/libghostty-spm/BinaryTarget/GhosttyKit.xcframework"

if ! command -v zig >/dev/null || [[ "$(zig version)" != "0.17.0" ]]; then
    echo "error: Ghostty v1.4.0 requires Zig 0.17.0" >&2
    exit 1
fi

patch_sha="$(shasum -a 256 "$patch" | awk '{print $1}')"
source_stamp="$revision $archive_sha $patch_sha"
script_sha="$(shasum -a 256 "$0" | awk '{print $1}')"
build_stamp="$(printf '%s\n%s\n%s\n%s\n' "$source_stamp" "$script_sha" "$(zig version)" "$(xcodebuild -version)" | shasum -a 256 | awk '{print $1}')"
if [[ -d "$framework" && -f "$work/framework-stamp" && "$(cat "$work/framework-stamp")" == "$build_stamp" ]]; then
    echo "→ libghostty v1.4.0 is already built"
    exit 0
fi

mkdir -p "$work"
if [[ ! -f "$work/source-stamp" || "$(cat "$work/source-stamp")" != "$source_stamp" || ! -f "$source_dir/build.zig" ]]; then
    archive="$work/ghostty-$revision.tar.gz"
    curl -fL --retry 3 -o "$archive" "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$revision"
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$archive_sha" ]]; then
        echo "error: Ghostty source archive checksum mismatch" >&2
        exit 1
    fi
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xzf "$archive" --strip-components=1 -C "$source_dir"
    git -C "$source_dir" apply --check "$patch"
    git -C "$source_dir" apply "$patch"
    printf '%s' "$source_stamp" > "$work/source-stamp"
fi

# Zig's downloader may not support the configured HTTPS proxy. curl and git
# populate the same package directory after Zig verifies each package hash.
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
    python3 "$root/scripts/fetch-libghostty-deps.py" "$source_dir" "$work/downloads"
fi

mkdir -p "$work/arm64" "$work/x86_64" "$work/headers/libghostty"
for arch in arm64 x86_64; do
    target="$arch"
    if [[ "$arch" == arm64 ]]; then target=aarch64; fi
    echo "→ building libghostty for $arch"
    (cd "$source_dir" && zig build \
        -Doptimize=fast -Dapp-runtime=none -Demit-exe=false \
        -Demit-xcframework=false -Demit-macos-app=false -Demit-docs=false \
        -Dsentry=false -Dcustom-shaders=false -Dinspector=false -Di18n=false \
        -Dtarget="$target-macos")
    cp "$source_dir/zig-out/lib/libghostty.a" "$work/$arch/libghostty.a"
done

cp "$source_dir/include/ghostty.h" "$work/headers/libghostty/ghostty.h"
cat > "$work/headers/libghostty/module.modulemap" <<'MAP'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
MAP
lipo -create "$work/arm64/libghostty.a" "$work/x86_64/libghostty.a" -output "$work/libghostty.a"
mkdir -p "$(dirname "$framework")"
staging="$work/framework-staging"
rm -rf "$staging"
mkdir -p "$staging"
xcodebuild -create-xcframework -library "$work/libghostty.a" -headers "$work/headers" -output "$staging/GhosttyKit.xcframework"
rm -rf "$framework"
mv "$staging/GhosttyKit.xcframework" "$framework"
printf '%s' "$build_stamp" > "$work/framework-stamp"
echo "→ built Ghostty v1.4.0 framework"

#!/bin/bash
# Build the patched Ghostty engine for both macOS architectures.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
revision=83fb95624b0439ee660c2679b43b38c8b63769cd
archive_sha=7759929eadaddf602d6fd5ad6b3403d854b91b7083975cd984bb525bc8275187
patch_dir="$root/Vendor/libghostty-spm/Patches"
series="$patch_dir/series"
work="$root/build/libghostty"
source_dir="$work/source"
framework="$root/Vendor/libghostty-spm/BinaryTarget/GhosttyKit.xcframework"

zig_version="$(zig version 2>/dev/null || true)"
# Match Ghostty's src/build/zig.zig: the major/minor must match, while
# newer patch releases are compatible. Keep development builds excluded.
if [[ ! "$zig_version" =~ ^0\.17\.[0-9]+$ ]]; then
    echo "error: Ghostty v1.4.0 requires a stable Zig 0.17.x release (found: ${zig_version:-not installed})" >&2
    exit 1
fi

patches=()
while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" =~ ^[a-zA-Z0-9.-]+\.patch$ && -f "$patch_dir/$name" ]] || { echo "error: invalid patch entry: $name" >&2; exit 1; }
    patches+=("$patch_dir/$name")
done < "$series"
[[ ${#patches[@]} -gt 0 ]] || { echo 'error: empty patch series' >&2; exit 1; }
patch_sha="$( { cat "$series"; for patch in "${patches[@]}"; do shasum -a 256 "$patch" | awk '{print $1}'; done; } | shasum -a 256 | awk '{print $1}')"
source_stamp="$revision $archive_sha $patch_sha"
script_sha="$(shasum -a 256 "$0" | awk '{print $1}')"
build_stamp="$(printf '%s\n%s\n%s\n%s\n' "$source_stamp" "$script_sha" "$zig_version" "$(xcodebuild -version)" | shasum -a 256 | awk '{print $1}')"
if [[ -d "$framework" && -f "$work/libghostty-vt.a" && -f "$work/framework-stamp" && "$(cat "$work/framework-stamp")" == "$build_stamp" ]]; then
    echo "→ libghostty v1.4.0 is already built"
    exit 0
fi

mkdir -p "$work"
if [[ ! -f "$work/source-stamp" || "$(cat "$work/source-stamp")" != "$source_stamp" || ! -f "$source_dir/build.zig" ]]; then
    archive="$work/ghostty-$revision.tar.gz"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 3 -o "$archive" "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$revision"
    fi
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$archive_sha" ]]; then
        echo "error: Ghostty source archive checksum mismatch" >&2
        exit 1
    fi
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xzf "$archive" --strip-components=1 -C "$source_dir"
    # The source lives under the 1Agent checkout. Isolate it so git apply
    # cannot silently skip every patch path relative to the parent repository.
    git -C "$source_dir" init -q
    for patch in "${patches[@]}"; do
        git -C "$source_dir" apply --check "$patch"
        git -C "$source_dir" apply "$patch"
    done
    if ! grep -q 'GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED' "$source_dir/include/ghostty.h" ||
       ! grep -q 'LIBGHOSTTY_SPM_TRIM_PATCH' "$source_dir/src/build/Config.zig"; then
        echo "error: Ghostty patches were not applied" >&2
        exit 1
    fi
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
        -Doptimize=fast -Dversion-string=1.4.0 -Dapp-runtime=none -Demit-exe=false \
        -Demit-xcframework=false -Demit-macos-app=false -Demit-docs=false \
        -Dsentry=false -Dcustom-shaders=false -Dinspector=false -Di18n=false \
        -Dtarget="$target-macos")
    cp "$source_dir/zig-out/lib/libghostty.a" "$work/$arch/libghostty.a"
    cp "$source_dir/zig-out/lib/libghostty-vt.a" "$work/$arch/libghostty-vt.a"
done

cp "$source_dir/include/ghostty.h" "$work/headers/libghostty/ghostty.h"
cat > "$work/headers/libghostty/module.modulemap" <<'MAP'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
MAP
lipo -create "$work/arm64/libghostty.a" "$work/x86_64/libghostty.a" -output "$work/libghostty.a"
lipo -create "$work/arm64/libghostty-vt.a" "$work/x86_64/libghostty-vt.a" -output "$work/libghostty-vt.a"
mkdir -p "$(dirname "$framework")"
staging="$work/framework-staging"
rm -rf "$staging"
mkdir -p "$staging"
xcodebuild -create-xcframework -library "$work/libghostty.a" -headers "$work/headers" -output "$staging/GhosttyKit.xcframework"
rm -rf "$framework"
mv "$staging/GhosttyKit.xcframework" "$framework"
printf '%s' "$build_stamp" > "$work/framework-stamp"
echo "→ built Ghostty v1.4.0 framework"

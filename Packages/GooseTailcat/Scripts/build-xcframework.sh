#!/bin/sh
# Build Artifacts/Tailcat.xcframework from the Go sources in go/.
#
# gomobile compiles the tailcatmobile package (which wraps the shared bridge
# package) into a per-platform framework and generates the Swift bindings.
# The checked-in xcframework is the normal build input; rerun this only when
# the Go sources or the tailcat dependency change — a dependency-maintenance
# operation, like GooseSSH's build-native.sh, not part of app or CI builds.
#
# Requires: go, and gomobile+gobind on PATH pinned to the golang.org/x/mobile
# version in go/go.mod (go install golang.org/x/mobile/cmd/gomobile@<version>
# && gomobile init). Run from anywhere; it cds to its own package.

set -eu

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_DIR="$PKG_DIR/go"
OUT="$PKG_DIR/Artifacts/Tailcat.xcframework"

GOPATH_BIN="$(go env GOPATH)/bin"
case ":$PATH:" in
  *":$GOPATH_BIN:"*) ;;
  *) PATH="$PATH:$GOPATH_BIN" ;;
esac

command -v gomobile >/dev/null 2>&1 || {
  echo "gomobile not found. Install it with:" >&2
  echo "  go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260908204917-8b95e45f8d3e && gomobile init" >&2
  exit 1
}

# -trimpath drops local build paths; -ldflags=-s -w strips the symbol and
# debug tables, which dominates the size of a Go static framework; an empty
# -buildid keeps the Go build ID out of the archive.
# GOFLAGS carries -trimpath too: gomobile forwards its own -trimpath
# inconsistently, so the go toolchain needs the flag directly.
#
# gomobile records the package directory as a module replace target in Go's
# build info, and neither -trimpath nor -buildid rewrites that entry
# (golang/go#40254, #73097). Binding from a neutral copy therefore keeps the
# caller's real workspace path out of the shipped archive; the fixed path also
# keeps successive builds byte-comparable.
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-trimpath"
SRC_DIR=/tmp/gooseagent-tailcat-src
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cp -R "$GO_DIR/." "$SRC_DIR/"
cd "$SRC_DIR"
rm -rf "$OUT"
CGO_ENABLED=1 gomobile bind \
  -target=ios,iossimulator,macos \
  -trimpath \
  -ldflags="-s -w -buildid=" \
  -o "$OUT" \
  ./tailcatmobile

echo "built $OUT"
find "$OUT" -maxdepth 1 -mindepth 1 -type d

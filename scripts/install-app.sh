#!/usr/bin/env bash
# After a Debug build: install Ghostty.app (bundle id com.mitchellh.ghostty) into /Applications.
# This app replaces the official Ghostty on this Mac:
# - official /Applications/Ghostty.app is zipped to ~/iLearn/backups, then removed
#   (refuses to continue while the official app is running);
# - the old /Applications/1Agent.app (com.itjun.1agent) is quit, zipped, and removed;
# - our own running build is quit, replaced, and relaunched.
set -euo pipefail

APP_NAME="Ghostty"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.mitchellh.ghostty"
OFFICIAL_TEAM="24VZTF6M5V"
DST="/Applications/$APP_BUNDLE"
# Our executable is "Ghostty"; the official one is lowercase "ghostty".
OUR_PROCESS="^${DST}/Contents/MacOS/${APP_NAME}( |$)"
OFFICIAL_PROCESS="/Contents/MacOS/ghostty( |$)"

LEGACY_BUNDLE_ID="com.itjun.1agent"
LEGACY_DST="/Applications/1Agent.app"
LEGACY_PROCESS="/1Agent.app/Contents/MacOS/1Agent( |$)"

BACKUP_DIR="$HOME/iLearn/backups"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  SRC="$ROOT/build/DerivedData.noindex/Build/Products/Debug/$APP_BUNDLE"
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: built app not found: $SRC" >&2
  exit 1
fi

team_of() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

# Quit by bundle id, wait up to ~15s, then force quit processes matching the pattern.
quit_app() {
  local bundle_id="$1" pattern="$2" label="$3"
  if ! pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi
  echo "→ ${label} is running; quitting…"
  osascript -e "tell application id \"${bundle_id}\" to quit" 2>/dev/null || true
  for _ in $(seq 1 30); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "→ ${label} still running; force quit"
  pkill -f "$pattern" 2>/dev/null || true
  sleep 0.5
}

# The official app shares our bundle id, so never quit anything while it runs: the user may be working in it.
if pgrep -f "$OFFICIAL_PROCESS" >/dev/null 2>&1; then
  echo "error: official Ghostty is running:" >&2
  pgrep -fl "$OFFICIAL_PROCESS" >&2 || true
  echo "error: quit it yourself, then run make build again. Nothing was changed." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

if [[ -d "$DST" && "$(team_of "$DST")" == "$OFFICIAL_TEAM" ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DST/Contents/Info.plist" 2>/dev/null || echo unknown)"
  zip="$BACKUP_DIR/Ghostty-${version}-official.app.zip"
  if [[ -e "$zip" ]]; then
    echo "→ official Ghostty backup already exists: $zip"
  else
    echo "→ backing up official Ghostty ${version} to $zip"
    ditto -c -k --keepParent "$DST" "$zip"
  fi
  "$LSREGISTER" -u "$DST" || true
  echo "→ removing official $DST"
  rm -rf "$DST"
fi

quit_app "$LEGACY_BUNDLE_ID" "$LEGACY_PROCESS" "1Agent"
if [[ -d "$LEGACY_DST" ]]; then
  echo "→ backing up $LEGACY_DST to $BACKUP_DIR/1Agent-last.app.zip"
  rm -f "$BACKUP_DIR/1Agent-last.app.zip"
  ditto -c -k --keepParent "$LEGACY_DST" "$BACKUP_DIR/1Agent-last.app.zip"
  "$LSREGISTER" -u "$LEGACY_DST" || true
  rm -rf "$LEGACY_DST"
fi

quit_app "$BUNDLE_ID" "$OUR_PROCESS" "$APP_NAME"

echo "→ installing to ${DST}"
rm -rf "$DST"
ditto "$SRC" "$DST"
# Touch so Launch Services / Dock pick up the new build
touch "$DST"

# Build products share the bundle id; keep only /Applications registered so
# `open -b` / other apps resolve com.mitchellh.ghostty to the installed copy.
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
LEGACY_BUILT="$(dirname "$SRC")/1Agent.app"
if [[ -d "$LEGACY_BUILT" ]]; then
  "$LSREGISTER" -u "$LEGACY_BUILT" 2>/dev/null || true
  rm -rf "$LEGACY_BUILT"
fi
# Older build folders (even deleted ones) can stay registered; drop every copy except /Applications.
"$LSREGISTER" -dump 2>/dev/null \
  | sed -nE 's#^path:[[:space:]]+(/.*/(Ghostty|1Agent)\.app) \(0x[0-9a-f]+\)$#\1#p' \
  | sort -u \
  | while IFS= read -r stale; do
      if [[ "$stale" != "$DST" ]]; then
        echo "→ unregistering stale copy: $stale"
        "$LSREGISTER" -u "$stale" 2>/dev/null || true
      fi
    done
"$LSREGISTER" -f "$DST"

echo "→ launching ${APP_NAME}"
open "$DST" || { sleep 1; open -n "$DST"; }
started=0
for _ in $(seq 1 30); do
  if pgrep -f "$OUR_PROCESS" >/dev/null 2>&1; then
    started=1
    break
  fi
  sleep 0.5
done
if [[ "$started" -ne 1 ]]; then
  echo "error: installed app did not start" >&2
  exit 1
fi
echo "→ installed app is running"

resolved="$(osascript -e "POSIX path of (path to application id \"${BUNDLE_ID}\")" 2>/dev/null || true)"
if [[ "$resolved" != "${DST}/" ]]; then
  echo "warning: ${BUNDLE_ID} resolves to '${resolved}', expected '${DST}/'" >&2
fi

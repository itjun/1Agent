#!/usr/bin/env bash
# After a Debug build: install 1Agent.app (bundle id com.itjun.1agent) into /Applications.
# Official Ghostty keeps /Applications/Ghostty.app, bundle id com.mitchellh.ghostty, and ghostty://.
# A previous build of this app that replaced Ghostty (executable "Ghostty", not "ghostty",
# and not signed by Ghostty's team) is quit and removed. If that leaves no Ghostty.app and
# ~/iLearn/backups has an official zip, the official app is unpacked back into /Applications.
set -euo pipefail

APP_NAME="1Agent"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.itjun.1agent"
DST="/Applications/$APP_BUNDLE"
OUR_PROCESS="^${DST}/Contents/MacOS/${APP_NAME}( |$)"

GHOSTTY_DST="/Applications/Ghostty.app"
OFFICIAL_TEAM="24VZTF6M5V"
OFFICIAL_BUNDLE_ID="com.mitchellh.ghostty"
IMPERSONATOR_PROCESS="^${GHOSTTY_DST}/Contents/MacOS/Ghostty( |$)"

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

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Quit the app at this path. Waits up to ~15s, then force-quits processes matching the pattern.
quit_bundle_path() {
  local app_path="$1" pattern="$2" label="$3"
  if ! pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi
  echo "→ ${label} is running; quitting…"
  osascript -e "tell application \"${app_path}\" to quit" 2>/dev/null || true
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

# Our old build used Ghostty's name and bundle id. The official executable is lowercase "ghostty".
if [[ -d "$GHOSTTY_DST" ]]; then
  team="$(team_of "$GHOSTTY_DST")"
  exe="$(plist_value "$GHOSTTY_DST" CFBundleExecutable)"
  bid="$(plist_value "$GHOSTTY_DST" CFBundleIdentifier)"
  if [[ "$exe" == "Ghostty" && "$bid" == "$OFFICIAL_BUNDLE_ID" && "$team" != "$OFFICIAL_TEAM" ]]; then
    quit_bundle_path "$GHOSTTY_DST" "$IMPERSONATOR_PROCESS" "1Agent (installed as Ghostty)"
    echo "→ removing this app's copy at $GHOSTTY_DST"
    "$LSREGISTER" -u "$GHOSTTY_DST" || true
    rm -rf "$GHOSTTY_DST"
  else
    echo "→ leaving $GHOSTTY_DST in place"
  fi
fi

if [[ ! -d "$GHOSTTY_DST" ]]; then
  newest=""
  newest_mtime=0
  for zip in "$BACKUP_DIR"/Ghostty-*-official.app.zip; do
    [[ -e "$zip" ]] || continue
    mtime="$(stat -f %m "$zip")"
    if [[ "$mtime" -gt "$newest_mtime" ]]; then
      newest="$zip"
      newest_mtime="$mtime"
    fi
  done
  if [[ -n "$newest" ]]; then
    echo "→ restoring official Ghostty from $newest"
    ditto -x -k "$newest" /Applications
    if [[ -d "$GHOSTTY_DST" ]]; then
      "$LSREGISTER" -f "$GHOSTTY_DST" || true
    else
      echo "warning: restore did not produce $GHOSTTY_DST" >&2
    fi
  fi
fi

quit_bundle_path "$DST" "$OUR_PROCESS" "$APP_NAME"

echo "→ installing to ${DST}"
rm -rf "$DST"
ditto "$SRC" "$DST"
# Touch so Launch Services / Dock pick up the new build
touch "$DST"

installed_id="$(plist_value "$DST" CFBundleIdentifier)"
installed_name="$(plist_value "$DST" CFBundleDisplayName)"
if [[ "$installed_id" != "$BUNDLE_ID" || "$installed_name" != "$APP_NAME" ]]; then
  echo "error: installed app is ${installed_name} (${installed_id}), expected ${APP_NAME} (${BUNDLE_ID})" >&2
  exit 1
fi

# Keep Launch Services pointed at /Applications for this app, and drop old build copies
# that still advertise Ghostty's bundle id. Never unregister the official Ghostty.app.
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
"$LSREGISTER" -dump 2>/dev/null \
  | sed -nE 's#^path:[[:space:]]+(/.*/(Ghostty|1Agent)\.app) \(0x[0-9a-f]+\)$#\1#p' \
  | sort -u \
  | while IFS= read -r stale; do
      if [[ "$stale" == "$DST" || "$stale" == "$GHOSTTY_DST" ]]; then
        continue
      fi
      echo "→ unregistering stale copy: $stale"
      "$LSREGISTER" -u "$stale" 2>/dev/null || true
    done
"$LSREGISTER" -f "$DST"
if [[ -d "$GHOSTTY_DST" ]]; then
  "$LSREGISTER" -f "$GHOSTTY_DST" || true
fi

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

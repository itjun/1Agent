#!/usr/bin/env bash
# After a Debug build: install Natty.app (bundle id com.itjun.natty) into /Applications.
# Official Ghostty keeps /Applications/Ghostty.app, bundle id com.mitchellh.ghostty, and ghostty://.
# A previous build of this app that replaced Ghostty (executable "Ghostty", not "ghostty",
# and not signed by Ghostty's team) is quit and removed. Only when removing that old build, if
# ~/iLearn/backups has an official zip, the official app is unpacked back into /Applications.
set -euo pipefail

APP_NAME="Natty"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.itjun.natty"
LEGACY_DST="/Applications/1Agent.app"
legacy_installed=0
DST="/Applications/$APP_BUNDLE"
OUR_PROCESS="^${DST}/Contents/MacOS/${APP_NAME}( |$)"

GHOSTTY_DST="/Applications/Ghostty.app"
OFFICIAL_TEAM="24VZTF6M5V"
OFFICIAL_BUNDLE_ID="com.mitchellh.ghostty"
IMPERSONATOR_PROCESS="^${GHOSTTY_DST}/Contents/MacOS/Ghostty( |$)"

BACKUP_DIR="$HOME/iLearn/backups"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
restore_official=0

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

# Quit the app at this path. Allow the installed Natty to keep running if it cannot save its sessions.
quit_bundle_path() {
  local app_path="$1" pattern="$2" label="$3"
  if ! pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi
  echo "→ ${label} is running; quitting…"
  local dictionary quit_command="quit"
  dictionary="$(plist_value "$app_path" OSAScriptingDefinition)"
  if grep -q 'code="tsKP"' "$app_path/Contents/Resources/$dictionary" 2>/dev/null; then
    quit_command="quit preserving terminal sessions true"
  fi
  osascript -e "tell application \"${app_path}\" to $quit_command" 2>/dev/null || true
  for _ in $(seq 1 30); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  if [[ "$app_path" == "$DST" || "$app_path" == "$LEGACY_DST" ]]; then
    echo "error: ${label} did not finish saving terminal sessions; installation stopped" >&2
    return 1
  fi
  echo "→ ${label} still running; force quit"
  pkill -f "$pattern" 2>/dev/null || true
  sleep 0.5
}

built_id="$(plist_value "$SRC" CFBundleIdentifier)"
built_name="$(plist_value "$SRC" CFBundleDisplayName)"
if [[ "$built_id" != "$BUNDLE_ID" || "$built_name" != "$APP_NAME" ]]; then
  echo "error: built app is ${built_name} (${built_id}), expected ${APP_NAME} (${BUNDLE_ID})" >&2
  exit 1
fi

# Our old build used Ghostty's name and bundle id. The official executable is lowercase "ghostty".
if [[ -d "$GHOSTTY_DST" ]]; then
  team="$(team_of "$GHOSTTY_DST")"
  exe="$(plist_value "$GHOSTTY_DST" CFBundleExecutable)"
  bid="$(plist_value "$GHOSTTY_DST" CFBundleIdentifier)"
  if [[ "$exe" == "Ghostty" && "$bid" == "$OFFICIAL_BUNDLE_ID" && "$team" != "$OFFICIAL_TEAM" ]]; then
    quit_bundle_path "$GHOSTTY_DST" "$IMPERSONATOR_PROCESS" "Natty (installed as Ghostty)"
    echo "→ removing this app's copy at $GHOSTTY_DST"
    "$LSREGISTER" -u "$GHOSTTY_DST" || true
    rm -rf "$GHOSTTY_DST"
    restore_official=1
  else
    echo "→ leaving $GHOSTTY_DST in place"
  fi
fi

if [[ ! -d "$GHOSTTY_DST" && "$restore_official" == 1 ]]; then
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

if [[ -e "$DST" && "$(plist_value "$DST" CFBundleIdentifier)" != "$BUNDLE_ID" ]]; then
  echo "error: $DST belongs to another application" >&2
  exit 1
fi
if [[ "$(plist_value "$LEGACY_DST" CFBundleExecutable)" == "1Agent" ]]; then
  case "$(plist_value "$LEGACY_DST" CFBundleIdentifier)" in
    com.itjun.agent|com.itjun.1agent)
      legacy_installed=1
      quit_bundle_path "$LEGACY_DST" '^/Applications/1Agent[.]app/Contents/MacOS/1Agent( |$)' "1Agent"
      ;;
  esac
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
  | sed -nE 's#^path:[[:space:]]+(/.*/(Ghostty|Natty)\.app) \(0x[0-9a-f]+\)$#\1#p' \
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
if [[ "$legacy_installed" == 1 ]]; then
  mkdir -p "$BACKUP_DIR"
  archive="$(mktemp -d "$BACKUP_DIR/1Agent-before-Natty.XXXXXX")"
  "$LSREGISTER" -u "$LEGACY_DST" || true
  mv "$LEGACY_DST" "$archive/1Agent.app.previous"
  echo "→ previous application saved to $archive"
  "$LSREGISTER" -f "$DST"
fi

resolved="$(osascript -e "POSIX path of (path to application id \"${BUNDLE_ID}\")" 2>/dev/null || true)"
if [[ "$resolved" != "${DST}/" ]]; then
  echo "warning: ${BUNDLE_ID} resolves to '${resolved}', expected '${DST}/'" >&2
fi

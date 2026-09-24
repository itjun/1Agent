#!/usr/bin/env bash
# After a Debug build: install Goose Agent.app into /Applications.
# If the app is running, quit first; always launch the installed build.
set -euo pipefail

APP_NAME="Goose Agent"
APP_BUNDLE="${APP_NAME}.app"
SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  SRC="$ROOT/build/Build/Products/Debug/$APP_BUNDLE"
fi
DST="/Applications/$APP_BUNDLE"

if [[ ! -d "$SRC" ]]; then
  echo "error: built app not found: $SRC" >&2
  exit 1
fi

was_running=0
if pgrep -f "/${APP_BUNDLE}/Contents/MacOS/" >/dev/null 2>&1 \
  || osascript -e "application id \"dev.eachann.gooseagent\" is running" 2>/dev/null | grep -qi true \
  || osascript -e "application \"${APP_NAME}\" is running" 2>/dev/null | grep -qi true; then
  was_running=1
fi

if [[ "$was_running" -eq 1 ]]; then
  echo "→ ${APP_NAME} is running; quitting…"
  osascript -e "tell application id \"dev.eachann.gooseagent\" to quit" 2>/dev/null \
    || osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null \
    || true
  # Wait until process exits (up to ~15s)
  for _ in $(seq 1 30); do
    if ! pgrep -f "/${APP_BUNDLE}/Contents/MacOS/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  if pgrep -f "^${DST}/Contents/MacOS/${APP_NAME}$" >/dev/null 2>&1; then
    echo "→ still running; force quit"
    pkill -f "/${APP_BUNDLE}/Contents/MacOS/" 2>/dev/null || true
    sleep 0.5
  fi
fi

echo "→ installing to ${DST}"
rm -rf "$DST"
ditto "$SRC" "$DST"
# Touch so Launch Services / Dock pick up the new build
touch "$DST"

echo "→ launching ${APP_NAME}"
open "$DST" || { sleep 1; open -n "$DST"; }
for _ in $(seq 1 30); do
  if pgrep -f "/${APP_BUNDLE}/Contents/MacOS/" >/dev/null 2>&1; then
    echo "→ installed app is running"
    exit 0
  fi
  sleep 0.5
done
echo "error: installed app did not start" >&2
exit 1

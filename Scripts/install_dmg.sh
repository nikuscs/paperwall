#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-$ROOT/dist/Paperwall.dmg}"
DESTINATION="${2:-$HOME/Applications/Paperwall.app}"
DESTINATION_DIR="$(dirname "$DESTINATION")"
STAGE="$DESTINATION_DIR/.Paperwall.app.stage-$$"
BACKUP="$DESTINATION_DIR/.Paperwall.app.rollback-$$"
USER_APP="$HOME/Applications/Paperwall.app"
USER_BACKUP="$HOME/Applications/.Paperwall.app.rollback-$$"
LOGIN_WAS_ENABLED=false
INSTALL_COMPLETE=false
MOUNT=""
PLIST="$(mktemp)"

cleanup() {
  local status=$?
  if [[ $status -ne 0 && "$INSTALL_COMPLETE" == false ]]; then
    if [[ -e "$BACKUP" ]]; then
      rm -rf -- "$DESTINATION"
      mv -- "$BACKUP" "$DESTINATION" || true
    fi
    if [[ -e "$USER_BACKUP" && ! -e "$USER_APP" ]]; then
      mv -- "$USER_BACKUP" "$USER_APP" || true
    fi
  fi
  rm -rf -- "$STAGE" "$BACKUP" "$USER_BACKUP"
  rm -f -- "$PLIST"
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap cleanup EXIT

[[ $EUID -ne 0 && "$HOME" != "/" && ! -L "$HOME" ]] || {
  echo "error: install as a non-root user with a real home directory" >&2
  exit 1
}
[[ -f "$DMG" ]] || { echo "error: DMG not found: $DMG" >&2; exit 1; }
case "$DESTINATION" in
  "$HOME/Applications/Paperwall.app") mkdir -p "$HOME/Applications" ;;
  "/Applications/Paperwall.app") ;;
  *) echo "error: unsupported app destination: $DESTINATION" >&2; exit 1 ;;
esac
[[ -d "$DESTINATION_DIR" && ! -L "$DESTINATION_DIR" && -w "$DESTINATION_DIR" ]] || {
  echo "error: app destination is not a writable real directory: $DESTINATION_DIR" >&2
  exit 1
}

hdiutil attach -nobrowse -readonly -plist "$DMG" >"$PLIST"
MOUNT="$(plutil -extract system-entities xml1 -o - "$PLIST" \
  | plutil -convert json -o - - \
  | python3 -c 'import json,sys; print(next(x["mount-point"] for x in json.load(sys.stdin) if "mount-point" in x))')"
[[ -d "$MOUNT/Paperwall.app" ]] || { echo "error: Paperwall.app missing from DMG" >&2; exit 1; }

/usr/bin/ditto "$MOUNT/Paperwall.app" "$STAGE"
codesign --verify --deep --strict "$STAGE"

if launchctl print "gui/$UID/com.paperwall.app" >/dev/null 2>&1; then
  LOGIN_WAS_ENABLED=true
fi
"$STAGE/Contents/Resources/Installer/paperwall" stop >/dev/null
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then mv "$DESTINATION" "$BACKUP"; fi
mv "$STAGE" "$DESTINATION"
if $LOGIN_WAS_ENABLED; then
  "$DESTINATION/Contents/Resources/Installer/paperwall" enable >/dev/null
fi
if [[ "$DESTINATION" == "/Applications/Paperwall.app" && -e "$USER_APP" ]]; then
  mv "$USER_APP" "$USER_BACKUP"
fi
open "$DESTINATION"
INSTALL_COMPLETE=true
rm -rf -- "$BACKUP" "$USER_BACKUP"
printf 'Installed %s from %s\n' "$DESTINATION" "$DMG"

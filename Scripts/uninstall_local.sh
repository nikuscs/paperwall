#!/usr/bin/env bash
set -euo pipefail

APP_DEST="$HOME/Applications/Paperwall.app"
SAVER_DEST="$HOME/Library/Screen Savers/Paperwall.saver"
SUPPORT_DIR="$HOME/Library/Application Support/Paperwall"
ASSET_DEST="$SUPPORT_DIR/current.mov"
POSTER_DEST="$SUPPORT_DIR/fallback.jpg"
WALLPAPER_BACKUP="$SUPPORT_DIR/native-wallpaper-backup.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.paperwall.app.plist"
CLI_DEST="$HOME/.local/bin/paperwall"
APP_EXECUTABLE="$APP_DEST/Contents/MacOS/Paperwall"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_ROOT=""
BACKUP_DESTINATIONS=()
BACKUP_COPIES=()
MUTATING=false
BACKUP_ROOT_CREATED=false
LAUNCH_AGENT_WAS_LOADED=false
LAUNCH_AGENT_WAS_RUNNING=false
APP_WAS_RUNNING=false
WALLPAPER_WAS_RESTORED=false

is_allowed() {
  case "$1" in
    "$APP_DEST"|"$SAVER_DEST"|"$ASSET_DEST"|"$POSTER_DEST"|"$WALLPAPER_BACKUP"|"$LAUNCH_AGENT"|"$CLI_DEST") return 0 ;;
    *) return 1 ;;
  esac
}

[[ $EUID -ne 0 && "$HOME" != "/" ]] || {
  echo "error: Paperwall must be uninstalled as a non-root user with a user home" >&2
  exit 1
}
[[ ! -L "$HOME" ]] || { echo "error: refusing symlinked HOME: $HOME" >&2; exit 1; }
HOME_REAL="$(cd "$HOME" && pwd -P)"
[[ "$HOME_REAL" == "$HOME" ]] || {
  echo "error: HOME must be its canonical physical path: $HOME" >&2
  exit 1
}

assert_safe_parent_chain() {
  local path="$1"
  local current
  current="$(dirname "$path")"
  while [[ "$current" != "$HOME" && "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      echo "error: refusing symlinked destination parent: $current" >&2
      return 1
    fi
    current="$(dirname "$current")"
  done
  [[ "$current" == "$HOME" ]] || {
    echo "error: destination is outside HOME: $path" >&2
    return 1
  }
}

safe_remove() {
  local path="$1"
  is_allowed "$path" || { echo "error: refusing non-allowlisted path: $path" >&2; return 1; }
  assert_safe_parent_chain "$path"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
    echo "Removed $path"
  fi
}

installed_paperwall_pids() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$executable" == "$APP_EXECUTABLE" ]]; then printf '%s\n' "$pid"; fi
  done < <(pgrep -x Paperwall 2>/dev/null || true)
}

snapshot() {
  local destination="$1"
  [[ -e "$destination" || -L "$destination" ]] || return 0
  local copy="$BACKUP_ROOT/${#BACKUP_COPIES[@]}"
  if [[ -L "$destination" ]]; then
    /bin/cp -P "$destination" "$copy"
  else
    /usr/bin/ditto "$destination" "$copy"
  fi
  BACKUP_DESTINATIONS+=("$destination")
  BACKUP_COPIES+=("$copy")
}

restore_snapshot() {
  local index destination copy
  local failed=0
  for ((index=0; index<${#BACKUP_COPIES[@]}; index++)); do
    destination="${BACKUP_DESTINATIONS[$index]}"
    copy="${BACKUP_COPIES[$index]}"
    /bin/rm -rf -- "$destination" || failed=1
    mkdir -p "$(dirname "$destination")" || failed=1
    if [[ -L "$copy" ]]; then
      /bin/cp -P "$copy" "$destination" || failed=1
    else
      /usr/bin/ditto "$copy" "$destination" || failed=1
    fi
  done
  if $LAUNCH_AGENT_WAS_LOADED; then
    if $LAUNCH_AGENT_WAS_RUNNING; then
      launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT" >/dev/null 2>&1 || failed=1
    else
      local restore_plist="$HOME/Library/LaunchAgents/.com.paperwall.app.restore-$STAMP.plist"
      if python3 - "$LAUNCH_AGENT" "$restore_plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    value = plistlib.load(source)
value["RunAtLoad"] = False
with open(sys.argv[2], "wb") as destination:
    plistlib.dump(value, destination)
PY
      then
        launchctl bootstrap "gui/$UID" "$restore_plist" >/dev/null 2>&1 || failed=1
        /bin/rm -f "$restore_plist" || failed=1
      else
        failed=1
      fi
    fi
    launchctl print "gui/$UID/com.paperwall.app" >/dev/null 2>&1 || failed=1
  fi
  if $WALLPAPER_WAS_RESTORED && [[ -x "$CLI_DEST" ]] && [[ -f "$ASSET_DEST" ]]; then
    "$CLI_DEST" __synchronize-native-wallpaper >/dev/null 2>&1 || failed=1
  fi
  if $APP_WAS_RUNNING && [[ -d "$APP_DEST" ]] && [[ -z "$(installed_paperwall_pids)" ]]; then
    open "$APP_DEST" >/dev/null 2>&1 || failed=1
  fi
  return "$failed"
}

cleanup() {
  local status=$?
  set +e
  set +u
  if [[ $status -ne 0 ]] && $MUTATING; then
    echo "Uninstall failed; restoring Paperwall." >&2
    if ! restore_snapshot; then
      echo "error: uninstall rollback incomplete; inspect $BACKUP_ROOT" >&2
      exit 70
    fi
  fi
  if $BACKUP_ROOT_CREATED && ! /bin/rm -rf -- "$BACKUP_ROOT"; then
    echo "error: could not remove uninstall snapshot: $BACKUP_ROOT" >&2
    exit 70
  fi
  exit "$status"
}
trap cleanup EXIT

for destination in "$APP_DEST" "$SAVER_DEST" "$ASSET_DEST" "$POSTER_DEST" "$WALLPAPER_BACKUP" "$LAUNCH_AGENT" "$CLI_DEST"; do
  assert_safe_parent_chain "$destination"
done
BACKUP_ROOT="$(mktemp -d "$HOME/.paperwall-uninstall.XXXXXX")"
BACKUP_ROOT_CREATED=true
for destination in "$LAUNCH_AGENT" "$APP_DEST" "$SAVER_DEST" "$ASSET_DEST" "$POSTER_DEST" "$WALLPAPER_BACKUP" "$CLI_DEST"; do
  snapshot "$destination"
done

if LAUNCH_STATE="$(launchctl print "gui/$UID/com.paperwall.app" 2>/dev/null)"; then
  LAUNCH_AGENT_WAS_LOADED=true
  [[ "$LAUNCH_STATE" == *"state = running"* ]] && LAUNCH_AGENT_WAS_RUNNING=true
fi
[[ -n "$(installed_paperwall_pids)" ]] && APP_WAS_RUNNING=true
MUTATING=true

if $LAUNCH_AGENT_WAS_LOADED; then
  launchctl bootout "gui/$UID/com.paperwall.app"
  for _ in {1..20}; do
    ! launchctl print "gui/$UID/com.paperwall.app" >/dev/null 2>&1 && break
    sleep 0.1
  done
  if launchctl print "gui/$UID/com.paperwall.app" >/dev/null 2>&1; then
    echo "error: Paperwall LaunchAgent is still loaded" >&2
    exit 1
  fi
fi

PIDS="$(installed_paperwall_pids)"
if [[ -n "$PIDS" ]]; then
  while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <<<"$PIDS"
  for _ in {1..30}; do
    [[ -z "$(installed_paperwall_pids)" ]] && break
    sleep 0.1
  done
  [[ -z "$(installed_paperwall_pids)" ]] || {
    echo "error: installed Paperwall process is still running" >&2
    exit 1
  }
fi

if [[ -e "$POSTER_DEST" || -e "$WALLPAPER_BACKUP" ]]; then
  [[ -x "$CLI_DEST" ]] || {
    echo "error: cannot restore native wallpaper because the Paperwall CLI is unavailable" >&2
    exit 1
  }
  "$CLI_DEST" __restore-native-wallpaper
  WALLPAPER_WAS_RESTORED=true
fi

safe_remove "$LAUNCH_AGENT"
safe_remove "$APP_DEST"
safe_remove "$SAVER_DEST"
safe_remove "$ASSET_DEST"
safe_remove "$POSTER_DEST"
safe_remove "$WALLPAPER_BACKUP"
safe_remove "$CLI_DEST"
rmdir "$SUPPORT_DIR" 2>/dev/null || true
MUTATING=false
/bin/rm -rf -- "$BACKUP_ROOT"
trap - EXIT

echo "Paperwall uninstall complete. Timestamped backup siblings were preserved."

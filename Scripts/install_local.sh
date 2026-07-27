#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Paperwall.xcodeproj"
DERIVED_DATA="$ROOT/build/DerivedData"
APP_DEST="$HOME/Applications/Paperwall.app"
SAVER_DEST="$HOME/Library/Screen Savers/Paperwall.saver"
SUPPORT_DIR="$HOME/Library/Application Support/Paperwall"
ASSET_DEST="$SUPPORT_DIR/current.mov"
CLI_DEST="$HOME/.local/bin/paperwall"
APP_EXECUTABLE="$APP_DEST/Contents/MacOS/Paperwall"
ASSET_SOURCE=""
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
STAGED=()
INSTALLED=()
BACKUP_DESTINATIONS=()
BACKUP_PATHS=()
APP_WAS_RUNNING=false
COMMITTED=false
CREATED_DIRECTORIES=()

usage() {
  cat <<'EOF'
Usage: Scripts/install_local.sh [--asset VIDEO]

Builds and installs Paperwall.app, Paperwall.saver, and the compiled `paperwall`
CLI to user-scoped locations. An optional initial video is copied into Paperwall storage.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --asset)
      [[ $# -ge 2 ]] || { echo "error: --asset requires a video path" >&2; exit 2; }
      ASSET_SOURCE="$(python3 - "$2" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -ne 0 && "$HOME" != "/" ]] || {
  echo "error: Paperwall must be installed as a non-root user with a user home" >&2
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

for destination in "$APP_DEST" "$SAVER_DEST" "$ASSET_DEST" "$CLI_DEST"; do
  assert_safe_parent_chain "$destination"
done

installed_paperwall_pids() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$executable" == "$APP_EXECUTABLE" ]]; then printf '%s\n' "$pid"; fi
  done < <(pgrep -x Paperwall 2>/dev/null || true)
}

[[ -n "$(installed_paperwall_pids)" ]] && APP_WAS_RUNNING=true

command -v xcodegen >/dev/null || { echo "error: xcodegen is required" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 1; }
command -v codesign >/dev/null || { echo "error: codesign is required" >&2; exit 1; }
if [[ -n "$ASSET_SOURCE" ]]; then
  [[ -f "$ASSET_SOURCE" ]] || { echo "error: asset not found: $ASSET_SOURCE" >&2; exit 1; }
  command -v ffprobe >/dev/null || { echo "error: ffprobe is required when --asset is used" >&2; exit 1; }
  [[ -n "$(ffprobe -v error -select_streams v:0 -show_entries stream=index -of csv=p=0 "$ASSET_SOURCE")" ]] || {
    echo "error: asset has no readable video track: $ASSET_SOURCE" >&2
    exit 1
  }
  EXPECTED_ASSET_HASH="$(shasum -a 256 "$ASSET_SOURCE" | awk '{print $1}')"
fi

rollback() {
  local index destination backup
  local failed=0
  for destination in "${INSTALLED[@]}"; do
    rm -rf -- "$destination" || failed=1
  done
  for ((index=${#BACKUP_PATHS[@]}-1; index>=0; index--)); do
    destination="${BACKUP_DESTINATIONS[$index]}"
    backup="${BACKUP_PATHS[$index]}"
    rm -rf -- "$destination" || failed=1
    if [[ -e "$backup" || -L "$backup" ]]; then
      if mv "$backup" "$destination"; then
        printf 'Restored %s from %s\n' "$destination" "$backup" >&2
      else
        failed=1
      fi
    else
      failed=1
    fi
  done
  if $APP_WAS_RUNNING && [[ -d "$APP_DEST" ]] && [[ -z "$(installed_paperwall_pids)" ]]; then
    open "$APP_DEST" >/dev/null 2>&1 || failed=1
  fi
  for ((index=${#CREATED_DIRECTORIES[@]}-1; index>=0; index--)); do
    rmdir "${CREATED_DIRECTORIES[$index]}" 2>/dev/null || failed=1
  done
  return "$failed"
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  set +e
  set +u
  for path in "${STAGED[@]}"; do
    rm -rf -- "$path" || cleanup_failed=1
  done
  if [[ $status -ne 0 ]] && ! $COMMITTED; then
    echo "Installation failed; rolling back destination changes." >&2
    if ! rollback; then
      echo "error: rollback incomplete; inspect the reported destinations" >&2
      status=70
    fi
  fi
  if [[ $cleanup_failed -ne 0 ]]; then
    echo "error: staging cleanup incomplete; inspect .Paperwall*.install-* paths" >&2
    status=70
  fi
  exit "$status"
}
trap cleanup EXIT

cd "$ROOT"
xcodegen generate
for scheme in PaperwallApp PaperwallScreenSaver PaperwallCLI; do
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
done

PRODUCTS="$DERIVED_DATA/Build/Products/Release"
[[ -d "$PRODUCTS/Paperwall.app" ]] || { echo "error: app build product missing" >&2; exit 1; }
[[ -d "$PRODUCTS/Paperwall.saver" ]] || { echo "error: saver build product missing" >&2; exit 1; }
[[ -x "$PRODUCTS/paperwall" ]] || { echo "error: CLI build product missing" >&2; exit 1; }

ensure_directory() {
  local directory="$1"
  [[ "$directory" == "$HOME" ]] && return 0
  if [[ -d "$directory" ]]; then return 0; fi
  [[ ! -e "$directory" && ! -L "$directory" ]] || {
    echo "error: destination directory is not a real directory: $directory" >&2
    return 1
  }
  ensure_directory "$(dirname "$directory")"
  mkdir "$directory"
  CREATED_DIRECTORIES+=("$directory")
}

ensure_directory "$HOME/Applications"
ensure_directory "$HOME/Library/Screen Savers"
ensure_directory "$HOME/.local/bin"
ensure_directory "$SUPPORT_DIR"
APP_STAGE="$HOME/Applications/.Paperwall.app.install-$STAMP"
SAVER_STAGE="$HOME/Library/Screen Savers/.Paperwall.saver.install-$STAMP"
CLI_STAGE="$HOME/.local/bin/.paperwall.install-$STAMP"
STAGED+=("$APP_STAGE" "$SAVER_STAGE" "$CLI_STAGE")
ditto "$PRODUCTS/Paperwall.app" "$APP_STAGE"
ditto "$PRODUCTS/Paperwall.saver" "$SAVER_STAGE"
if [[ -n "$ASSET_SOURCE" ]]; then
  ASSET_STAGE="$SUPPORT_DIR/.current.mov.install-$STAMP"
  STAGED+=("$ASSET_STAGE")
  cp "$ASSET_SOURCE" "$ASSET_STAGE"
  [[ "$(shasum -a 256 "$ASSET_SOURCE" | awk '{print $1}')" == "$EXPECTED_ASSET_HASH" ]] || {
    echo "error: source asset changed during the build" >&2
    exit 1
  }
  [[ "$(shasum -a 256 "$ASSET_STAGE" | awk '{print $1}')" == "$EXPECTED_ASSET_HASH" ]] || {
    echo "error: staged asset hash mismatch" >&2
    exit 1
  }
  [[ -n "$(ffprobe -v error -select_streams v:0 -show_entries stream=index -of csv=p=0 "$ASSET_STAGE")" ]] || {
    echo "error: staged asset has no readable video track" >&2
    exit 1
  }
fi
cp "$PRODUCTS/paperwall" "$CLI_STAGE"
codesign --force --deep --sign - "$APP_STAGE"
codesign --force --deep --sign - "$SAVER_STAGE"
codesign --force --sign - "$CLI_STAGE"
codesign --verify --deep --strict "$APP_STAGE"
codesign --verify --deep --strict "$SAVER_STAGE"
codesign --verify --strict "$CLI_STAGE"

backup_existing() {
  local destination="$1"
  assert_safe_parent_chain "$destination"
  if [[ -e "$destination" || -L "$destination" ]]; then
    local backup="${destination}.backup-${STAMP}"
    mv "$destination" "$backup"
    BACKUP_DESTINATIONS+=("$destination")
    BACKUP_PATHS+=("$backup")
    printf 'Backed up %s to %s\n' "$destination" "$backup"
  fi
}

install_staged() {
  local staged="$1"
  local destination="$2"
  backup_existing "$destination"
  mv "$staged" "$destination"
  INSTALLED+=("$destination")
}

PIDS="$(installed_paperwall_pids)"
if [[ -n "$PIDS" ]]; then
  while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <<<"$PIDS"
  for _ in {1..30}; do
    [[ -z "$(installed_paperwall_pids)" ]] && break
    sleep 0.1
  done
  [[ -z "$(installed_paperwall_pids)" ]] || {
    echo "error: installed Paperwall process did not stop before replacement" >&2
    exit 1
  }
fi

install_staged "$APP_STAGE" "$APP_DEST"
install_staged "$SAVER_STAGE" "$SAVER_DEST"
if [[ -n "$ASSET_SOURCE" ]]; then
  install_staged "$ASSET_STAGE" "$ASSET_DEST"
fi
install_staged "$CLI_STAGE" "$CLI_DEST"
codesign --force --deep --sign - "$APP_DEST"
codesign --force --deep --sign - "$SAVER_DEST"
codesign --verify --deep --strict "$APP_DEST"
codesign --verify --deep --strict "$SAVER_DEST"
codesign --verify --strict "$CLI_DEST"

if $APP_WAS_RUNNING; then
  open "$APP_DEST"
fi

COMMITTED=true
trap - EXIT
printf 'Installed %s\nInstalled %s\nInstalled %s\n' "$APP_DEST" "$SAVER_DEST" "$CLI_DEST"
if [[ -n "$ASSET_SOURCE" ]]; then
  printf 'Installed %s\n' "$ASSET_DEST"
fi

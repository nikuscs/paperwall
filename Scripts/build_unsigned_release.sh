#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist/Paperwall-unsigned.zip}"
TOOLS_DIR="${PAPERWALL_RELEASE_TOOLS_DIR:-$ROOT/build/release-tools/bin}"
DERIVED_DATA="$ROOT/build/UnsignedReleaseDerivedData"
APP="$DERIVED_DATA/Build/Products/Release/Paperwall.app"

command -v xcodebuild >/dev/null || { echo "error: Xcode is required" >&2; exit 1; }
"$ROOT/Scripts/bootstrap_release_tools.sh" "$TOOLS_DIR"
export PAPERWALL_UV_BINARY="$TOOLS_DIR/uv"

rm -rf "$DERIVED_DATA"
"$TOOLS_DIR/xcodegen" generate --spec "$ROOT/project.yml" --project "$ROOT"
git -C "$ROOT" diff --exit-code -- Paperwall.xcodeproj/project.pbxproj >/dev/null || {
  echo "error: generated Xcode project differs from the tagged project; regenerate and commit it" >&2
  exit 1
}
xcodebuild build \
  -project "$ROOT/Paperwall.xcodeproj" \
  -scheme PaperwallApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

[[ -d "$APP" ]] || { echo "error: Paperwall.app build product missing" >&2; exit 1; }
[[ -x "$APP/Contents/Resources/Installer/paperwall" ]] || { echo "error: embedded CLI missing" >&2; exit 1; }
[[ -d "$APP/Contents/Resources/Installer/Paperwall.saver" ]] || { echo "error: embedded screen saver missing" >&2; exit 1; }
[[ -x "$APP/Contents/Resources/Tools/uv" ]] || { echo "error: embedded uv missing" >&2; exit 1; }
[[ -d "$APP/Contents/Extensions/PaperwallWallpaperExtension.appex" ]] || { echo "error: wallpaper extension missing" >&2; exit 1; }
cmp -s "$TOOLS_DIR/uv" "$APP/Contents/Resources/Tools/uv" || { echo "error: embedded uv differs from the verified release tool" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT"
shasum -a 256 "$OUTPUT" | awk -v name="$(basename "$OUTPUT")" '{print $1 "  " name}' > "$OUTPUT.sha256"
printf 'Created unsigned release artifact %s\n' "$OUTPUT"

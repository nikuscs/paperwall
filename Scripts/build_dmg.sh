#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Paperwall.xcodeproj"
DERIVED_DATA="$ROOT/build/DistributionDerivedData"
DIST="$ROOT/dist"
STAGING="$ROOT/build/dmg-staging"
APP="$DERIVED_DATA/Build/Products/Release/Paperwall.app"
DMG="$DIST/Paperwall.dmg"
IDENTITY="${PAPERWALL_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${PAPERWALL_NOTARY_PROFILE:-}"
TOOLS_DIR="${PAPERWALL_RELEASE_TOOLS_DIR:-$ROOT/build/release-tools/bin}"

command -v xcodebuild >/dev/null || { echo "error: Xcode is required" >&2; exit 1; }
command -v hdiutil >/dev/null || { echo "error: hdiutil is required" >&2; exit 1; }
"$ROOT/Scripts/bootstrap_release_tools.sh" "$TOOLS_DIR"
XCODEGEN="$TOOLS_DIR/xcodegen"
export PAPERWALL_UV_BINARY="$TOOLS_DIR/uv"

cd "$ROOT"
"$XCODEGEN" generate
xcodebuild build \
  -project "$PROJECT" \
  -scheme PaperwallApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

[[ -d "$APP" ]] || { echo "error: Paperwall.app build product missing" >&2; exit 1; }
[[ -x "$APP/Contents/Resources/Installer/paperwall" ]] || { echo "error: embedded CLI missing" >&2; exit 1; }
[[ -d "$APP/Contents/Resources/Installer/Paperwall.saver" ]] || { echo "error: embedded screen saver missing" >&2; exit 1; }
[[ -x "$APP/Contents/Resources/Tools/uv" ]] || { echo "error: embedded uv bootstrap missing" >&2; exit 1; }
[[ -d "$APP/Contents/Extensions/PaperwallWallpaperExtension.appex" ]] || { echo "error: native wallpaper extension missing" >&2; exit 1; }

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --entitlements "$ROOT/Config/PaperwallWallpaperExtension.entitlements" \
    "$APP/Contents/Extensions/PaperwallWallpaperExtension.appex"
  codesign --force --sign - "$APP/Contents/Resources/Tools/uv"
  codesign --force --sign - "$APP/Contents/Resources/Installer/paperwall"
  codesign --force --deep --sign - "$APP/Contents/Resources/Installer/Paperwall.saver"
  codesign --force --deep --sign - "$APP/Contents/Frameworks/PaperwallPlayback.framework"
  codesign --force --sign - --entitlements "$ROOT/Config/PaperwallApp.entitlements" "$APP"
  echo "warning: created an ad-hoc signed development DMG; public distribution requires Developer ID and notarization" >&2
else
  codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" \
    --entitlements "$ROOT/Config/PaperwallWallpaperExtension.entitlements" \
    "$APP/Contents/Extensions/PaperwallWallpaperExtension.appex"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Tools/uv"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Installer/paperwall"
  codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Installer/Paperwall.saver"
  codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/PaperwallPlayback.framework"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    --entitlements "$ROOT/Config/PaperwallApp.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST"
ditto "$APP" "$STAGING/Paperwall.app"
cp "$ROOT/LICENSE.md" "$STAGING/LICENSE.md"
cp "$ROOT/PRIVACY.md" "$STAGING/PRIVACY.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.md"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname Paperwall -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify --strict "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  [[ "$IDENTITY" != "-" ]] || { echo "error: notarization requires PAPERWALL_SIGN_IDENTITY" >&2; exit 1; }
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

rm -rf "$STAGING"
printf 'Created %s\n' "$DMG"

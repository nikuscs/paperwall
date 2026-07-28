#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNSIGNED_ZIP="${1:?usage: sign_release_artifact.sh UNSIGNED_ZIP EXPECTED_SHA256 OUTPUT_DMG}"
EXPECTED_SHA256="${2:?usage: sign_release_artifact.sh UNSIGNED_ZIP EXPECTED_SHA256 OUTPUT_DMG}"
OUTPUT_DMG="${3:?usage: sign_release_artifact.sh UNSIGNED_ZIP EXPECTED_SHA256 OUTPUT_DMG}"
IDENTITY="${PAPERWALL_SIGN_IDENTITY:?PAPERWALL_SIGN_IDENTITY is required}"
NOTARY_PROFILE="${PAPERWALL_NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${PAPERWALL_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${PAPERWALL_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${PAPERWALL_NOTARY_ISSUER_ID:-}"

[[ "$IDENTITY" != "-" ]] || { echo "error: Developer ID signing identity is required" >&2; exit 1; }
[[ -f "$UNSIGNED_ZIP" ]] || { echo "error: unsigned artifact missing: $UNSIGNED_ZIP" >&2; exit 1; }
ACTUAL_SHA256="$(shasum -a 256 "$UNSIGNED_ZIP" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "error: unsigned artifact digest mismatch" >&2
  echo "expected: $EXPECTED_SHA256" >&2
  echo "actual:   $ACTUAL_SHA256" >&2
  exit 1
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  [[ -f "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] || {
    echo "error: notarization requires PAPERWALL_NOTARY_PROFILE or API-key credentials" >&2
    exit 1
  }
fi

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/paperwall-sign-release.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
EXTRACTED="$TEMP/extracted"
STAGING="$TEMP/dmg"
mkdir -p "$EXTRACTED" "$STAGING" "$(dirname "$OUTPUT_DMG")"
ditto -x -k "$UNSIGNED_ZIP" "$EXTRACTED"
APP="$EXTRACTED/Paperwall.app"
[[ -d "$APP" ]] || { echo "error: unsigned archive does not contain Paperwall.app" >&2; exit 1; }

codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" \
  --entitlements "$ROOT/Config/PaperwallWallpaperExtension.entitlements" \
  "$APP/Contents/Extensions/PaperwallWallpaperExtension.appex"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Tools/uv"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Installer/paperwall"
codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/Installer/Paperwall.saver"
codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/PaperwallPlayback.framework"
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  --entitlements "$ROOT/Config/PaperwallApp.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

cp -R "$APP" "$STAGING/Paperwall.app"
cp "$ROOT/LICENSE.md" "$STAGING/LICENSE.md"
cp "$ROOT/PRIVACY.md" "$STAGING/PRIVACY.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.md"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUTPUT_DMG" "$OUTPUT_DMG.sha256"
hdiutil create -volname Paperwall -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT_DMG"
codesign --force --timestamp --sign "$IDENTITY" "$OUTPUT_DMG"
codesign --verify --strict "$OUTPUT_DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$OUTPUT_DMG" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
fi
xcrun stapler staple "$OUTPUT_DMG"
xcrun stapler validate "$OUTPUT_DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT_DMG"
shasum -a 256 "$OUTPUT_DMG" | awk -v name="$(basename "$OUTPUT_DMG")" '{print $1 "  " name}' > "$OUTPUT_DMG.sha256"
printf 'Created signed and notarized release %s\n' "$OUTPUT_DMG"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/build/release-tools/bin}"
CONFIG="$ROOT/Config/release-tools.env"

[[ -f "$CONFIG" ]] || { echo "error: release tool configuration missing: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

case "$(uname -m)" in
  arm64)
    UV_TARGET="aarch64-apple-darwin"
    UV_SHA256="$UV_ARM64_SHA256"
    GITLEAKS_ARCH="arm64"
    GITLEAKS_SHA256="$GITLEAKS_ARM64_SHA256"
    ;;
  x86_64)
    UV_TARGET="x86_64-apple-darwin"
    UV_SHA256="$UV_X86_64_SHA256"
    GITLEAKS_ARCH="x64"
    GITLEAKS_SHA256="$GITLEAKS_X86_64_SHA256"
    ;;
  *)
    echo "error: unsupported release-tool architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

for command in curl shasum tar unzip; do
  command -v "$command" >/dev/null || { echo "error: required bootstrap command missing: $command" >&2; exit 1; }
done

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/paperwall-release-tools.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$DESTINATION"

fetch_verified() {
  local url="$1"
  local expected="$2"
  local output="$3"
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 \
    --output "$output" "$url"
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: checksum mismatch for $url" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

UV_ARCHIVE="$TEMP/uv.tar.gz"
fetch_verified \
  "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_TARGET.tar.gz" \
  "$UV_SHA256" \
  "$UV_ARCHIVE"
mkdir -p "$TEMP/uv"
tar -xzf "$UV_ARCHIVE" -C "$TEMP/uv"
UV_BINARY="$(find "$TEMP/uv" -type f -name uv -perm -111 -print -quit)"
[[ -n "$UV_BINARY" ]] || { echo "error: verified uv archive did not contain uv" >&2; exit 1; }
install -m 755 "$UV_BINARY" "$DESTINATION/uv"

XCODEGEN_ARCHIVE="$TEMP/xcodegen.zip"
fetch_verified \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
  "$XCODEGEN_SHA256" \
  "$XCODEGEN_ARCHIVE"
mkdir -p "$TEMP/xcodegen"
unzip -q "$XCODEGEN_ARCHIVE" -d "$TEMP/xcodegen"
XCODEGEN_BINARY="$(find "$TEMP/xcodegen" -type f -path '*/bin/xcodegen' -perm -111 -print -quit)"
XCODEGEN_SHARE="$(find "$TEMP/xcodegen" -type d -path '*/share/xcodegen' -print -quit)"
[[ -n "$XCODEGEN_BINARY" && -n "$XCODEGEN_SHARE" ]] || { echo "error: verified XcodeGen archive is incomplete" >&2; exit 1; }
install -m 755 "$XCODEGEN_BINARY" "$DESTINATION/xcodegen"
rm -rf "$(dirname "$DESTINATION")/share/xcodegen"
mkdir -p "$(dirname "$DESTINATION")/share"
cp -R "$XCODEGEN_SHARE" "$(dirname "$DESTINATION")/share/xcodegen"

GITLEAKS_ARCHIVE="$TEMP/gitleaks.tar.gz"
fetch_verified \
  "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_darwin_${GITLEAKS_ARCH}.tar.gz" \
  "$GITLEAKS_SHA256" \
  "$GITLEAKS_ARCHIVE"
mkdir -p "$TEMP/gitleaks"
tar -xzf "$GITLEAKS_ARCHIVE" -C "$TEMP/gitleaks"
GITLEAKS_BINARY="$(find "$TEMP/gitleaks" -type f -name gitleaks -perm -111 -print -quit)"
[[ -n "$GITLEAKS_BINARY" ]] || { echo "error: verified Gitleaks archive did not contain gitleaks" >&2; exit 1; }
install -m 755 "$GITLEAKS_BINARY" "$DESTINATION/gitleaks"

[[ "$("$DESTINATION/uv" --version)" == "uv $UV_VERSION"* ]] || { echo "error: uv version verification failed" >&2; exit 1; }
[[ "$("$DESTINATION/xcodegen" --version)" == "Version: $XCODEGEN_VERSION" ]] || { echo "error: XcodeGen version verification failed" >&2; exit 1; }
[[ "$("$DESTINATION/gitleaks" version)" == "$GITLEAKS_VERSION" ]] || { echo "error: Gitleaks version verification failed" >&2; exit 1; }

cat > "$DESTINATION/manifest.sha256" <<MANIFEST
$(shasum -a 256 "$DESTINATION/uv" | awk '{print $1}')  uv
$(shasum -a 256 "$DESTINATION/xcodegen" | awk '{print $1}')  xcodegen
$(shasum -a 256 "$DESTINATION/gitleaks" | awk '{print $1}')  gitleaks
MANIFEST

printf 'Prepared verified release tools in %s\n' "$DESTINATION"

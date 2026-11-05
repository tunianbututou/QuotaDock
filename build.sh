#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Sources"
STAGE="$HERE/build"
APP="$STAGE/QuotaDock.app"
BASE="/Applications/QuotaDock.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

CODEX_RUNTIME="${QUOTADOCK_CODEX_PATH:-}"
if [[ -z "$CODEX_RUNTIME" ]]; then
  CODEX_RUNTIME="$(command -v codex || true)"
fi
if [[ -z "$CODEX_RUNTIME" && -x "$BASE/Contents/Helpers/codex" ]]; then
  CODEX_RUNTIME="$BASE/Contents/Helpers/codex"
fi

if [[ ! -f "$CODEX_RUNTIME" || ! -x "$CODEX_RUNTIME" ]]; then
  echo "QuotaDock needs a local Codex helper executable." >&2
  echo "Install Codex or set QUOTADOCK_CODEX_PATH to its codex executable." >&2
  exit 1
fi

echo "==> compile QuotaDock (arm64, macOS 14+)"
mkdir -p "$STAGE"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -sdk "$SDK" \
  "$SRC"/*.swift -o "$STAGE/QuotaDock"

echo "==> assemble app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$STAGE/QuotaDock" "$APP/Contents/MacOS/QuotaDock"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/QuotaDock.icns" "$APP/Contents/Resources/QuotaDock.icns"
cp "$CODEX_RUNTIME" "$APP/Contents/Helpers/codex"
chmod +x "$APP/Contents/MacOS/QuotaDock" "$APP/Contents/Helpers/codex"

echo "==> ad-hoc sign"
codesign --force --sign - --entitlements "$HERE/Helper.entitlements" \
  "$APP/Contents/Helpers/codex"
codesign --force --sign - --entitlements "$HERE/QuotaDock.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "install" ]]; then
  echo "==> install"
  if [[ -d "$BASE" ]]; then
    pkill -f "QuotaDock.app/Contents/MacOS/QuotaDock" 2>/dev/null || true
    sleep 2
    rm -rf "$STAGE/prev.app"
    mv "$BASE" "$STAGE/prev.app"
  fi
  cp -R "$APP" "$BASE"
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$BASE" 2>/dev/null || true
  open -a "$BASE"
  echo "Installed: $BASE"
fi

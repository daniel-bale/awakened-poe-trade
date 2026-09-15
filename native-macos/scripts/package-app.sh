#!/bin/bash
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
CONFIGURATION=release
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"

case "${1:-}" in
  --debug) CONFIGURATION=debug ;;
  --help|-h)
    echo "Usage: $0 [--debug]"
    echo "Build and sign native-macos/dist/Awakened PoE Trade.app."
    echo "Set CODE_SIGN_IDENTITY to an existing signing identity name or SHA-1 fingerprint."
    echo "The default is '-' (ad-hoc); changed builds may require Accessibility remove/re-add."
    exit 0
    ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--debug]" >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo "The native app must be built on macOS." >&2
  exit 1
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Warning: ad-hoc signing identifies this build only. After a changed build, Accessibility approval may require removing and re-adding the app in System Settings." >&2
fi

npm --prefix "$NATIVE_DIR/bridge" run build
# Keep compiler and SwiftPM state beside the build, including on restricted hosts.
export CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
SWIFT_BUILD_ARGS=(
  --package-path "$NATIVE_DIR"
  --configuration "$CONFIGURATION"
  --cache-path "$NATIVE_DIR/.build/package-cache"
  --config-path "$NATIVE_DIR/.build/package-config"
  --security-path "$NATIVE_DIR/.build/package-security"
  --disable-sandbox
)
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/AwakenedPoeTrade"
RESOURCE_BUNDLE="$BIN_DIR/AwakenedPoeTradeNative_TradeCore.bundle"
if [[ ! -x "$EXECUTABLE" || ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "The build did not produce the app executable and TradeCore resource bundle." >&2
  exit 1
fi

DIST_DIR="$NATIVE_DIR/dist"
APP_PATH="$DIST_DIR/Awakened PoE Trade.app"
mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Awakened PoE Trade.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$EXECUTABLE" "$STAGED_APP/Contents/MacOS/AwakenedPoeTrade"
cp "$NATIVE_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp -R "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/"
cp "$REPO_DIR/main/build/icons/icon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
mkdir -p "$STAGED_APP/Contents/Resources/fonts"
for font in Fontin-SmallCaps-Hinted Exo2-Regular Exo2-SemiBold; do
  cp "$REPO_DIR/renderer/src/assets/font/$font.ttf" "$STAGED_APP/Contents/Resources/fonts/"
done
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Replace only this script's generated app, after a successful build and signature.
if [[ -e "$APP_PATH" ]]; then
  if [[ -L "$APP_PATH" || ! -d "$APP_PATH/Contents" ]]; then
    echo "Refusing to replace a non-app path: $APP_PATH" >&2
    exit 1
  fi
  rm -rf "$APP_PATH"
fi
mv "$STAGED_APP" "$APP_PATH"
echo "Built: $APP_PATH"

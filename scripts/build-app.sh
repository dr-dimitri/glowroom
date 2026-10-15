#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release

case "${1:-}" in
    "") ;;
    --debug) CONFIGURATION=debug ;;
    --help|-h)
        echo "Usage: $0 [--debug]"
        echo "Builds dist/PicEdit.app for the current Mac (release by default)."
        exit 0
        ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--debug]" >&2
    exit 2
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is missing. Install Apple's developer tools with xcode-select --install." >&2
    exit 1
fi

BUILD_PATH="${PICEDIT_BUILD_PATH:-"$ROOT/.build"}"
if [[ "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$ROOT/$BUILD_PATH"
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$BUILD_PATH/ModuleCache" "$ROOT/dist"
BUILD_ARGS=(--disable-sandbox --package-path "$ROOT" --configuration "$CONFIGURATION" --scratch-path "$BUILD_PATH")
if [[ -n "${PICEDIT_BUILD_SYSTEM:-}" ]]; then
    BUILD_ARGS+=(--build-system "$PICEDIT_BUILD_SYSTEM")
fi

swift build "${BUILD_ARGS[@]}" --product PicEdit
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

STAGING="$(mktemp -d "$ROOT/dist/.picedit-build.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
APP="$STAGING/PicEdit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/PicEdit" "$APP/Contents/MacOS/PicEdit"
chmod 755 "$APP/Contents/MacOS/PicEdit"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleDisplayName</key><string>PicEdit</string>
    <key>CFBundleExecutable</key><string>PicEdit</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>de.wolfgangbauer.picedit</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PicEdit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

ICONSET="$STAGING/AppIcon.iconset"
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$ROOT/scripts/make-app-icon.swift" "$ICONSET"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
plutil -lint "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
fi

DESTINATION="$ROOT/dist/PicEdit.app"
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    rm -rf -- "$DESTINATION"
fi
mv "$APP" "$DESTINATION"
echo "Built $DESTINATION"
echo "Open it with: open \"$DESTINATION\""

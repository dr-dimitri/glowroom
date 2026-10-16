#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
BINARY="$("$ROOT/scripts/build-developer-tool.sh" keychain)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/picedit-keychain-smoke.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
APP="$STAGING/PicEditKeychainSmoke.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PicEditKeychainSmoke"
for RESOURCE_BUNDLE in "$(dirname -- "$BINARY")"/*.bundle; do
    [[ -d "$RESOURCE_BUNDLE" ]] || continue
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PicEditKeychainSmoke</string>
<key>CFBundleIdentifier</key><string>de.wolfgangbauer.picedit.keychain-smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# Match build-app.sh's ordinary ad-hoc signature, without DP entitlements.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/PicEditKeychainSmoke"

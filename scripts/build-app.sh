#!/bin/bash
set -euo pipefail

# A developer shell must never package a benchmark entry point as the app.
unset PICEDIT_DEVELOPER_TOOL

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release

case "${1:-}" in
    "") ;;
    --debug) CONFIGURATION=debug ;;
    --help|-h)
        echo "Usage: $0 [--debug]"
        echo "Builds dist/PicEdit.app for the current Mac (release by default)."
        echo "PICEDIT_BUILD_JOBS=1..1024 overrides the automatic CPU/memory job budget."
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

# Budget includes one icon worker while the compiler runs. Two GiB per
# scheduled worker is a conservative memory limit, not a usage prediction.
if [[ -n "${PICEDIT_BUILD_JOBS+x}" ]]; then
    if [[ ! "$PICEDIT_BUILD_JOBS" =~ ^[1-9][0-9]{0,3}$ ]] || (( PICEDIT_BUILD_JOBS > 1024 )); then
        echo "PICEDIT_BUILD_JOBS must be an integer between 1 and 1024." >&2
        exit 2
    fi
    JOB_BUDGET="$PICEDIT_BUILD_JOBS"
else
    CPU_COUNT="$(sysctl -n hw.activecpu 2>/dev/null || true)"
    MEMORY_BYTES="$(sysctl -n hw.memsize 2>/dev/null || true)"
    [[ "$CPU_COUNT" =~ ^[1-9][0-9]{0,3}$ ]] || CPU_COUNT=1
    JOB_BUDGET="$CPU_COUNT"
    if [[ "$MEMORY_BYTES" =~ ^[1-9][0-9]{0,15}$ ]]; then
        MEMORY_JOBS=$(( MEMORY_BYTES / 2147483648 ))
        (( MEMORY_JOBS > 0 )) || MEMORY_JOBS=1
        if (( MEMORY_JOBS < JOB_BUDGET )); then JOB_BUDGET="$MEMORY_JOBS"; fi
    else
        # Unknown capacity: remain functional without assuming spare memory.
        JOB_BUDGET=1
    fi
fi
COMPILER_JOBS="$JOB_BUDGET"
if (( JOB_BUDGET > 1 )); then COMPILER_JOBS=$(( JOB_BUDGET - 1 )); fi

BUILD_PATH="${PICEDIT_BUILD_PATH:-"$ROOT/.build"}"
if [[ "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$ROOT/$BUILD_PATH"
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$ROOT/dist"
LOCK="$ROOT/dist/.picedit-build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Another bundle build owns $LOCK (PID: $(cat "$LOCK/pid" 2>/dev/null || echo unknown))." >&2
    echo "Wait for it to finish. After a crash, remove this lock only if its owner is no longer running." >&2
    exit 1
fi
STAGING=""
COMPILE_PID=""
ICON_PID=""
DESTINATION="$ROOT/dist/PicEdit.app"
cleanup() {
    local result=$?
    local worker
    local keep_staging=0
    trap - EXIT INT TERM
    for worker in "$COMPILE_PID" "$ICON_PID"; do
        if [[ -n "$worker" ]]; then
            # Each background job has its own process group, including compiler
            # children. Stop and reap it before deleting its staging files.
            kill -TERM -- "-$worker" 2>/dev/null || true
            wait "$worker" 2>/dev/null || true
        fi
    done
    if [[ -n "$STAGING" ]]; then
        if [[ -e "$STAGING/Previous.app" || -L "$STAGING/Previous.app" ]]; then
            if [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]]; then
                if ! mv "$STAGING/Previous.app" "$DESTINATION"; then
                    echo "Previous app retained at $STAGING/Previous.app; automatic rollback failed." >&2
                    keep_staging=1
                fi
            fi
        fi
        if (( keep_staging == 0 )); then rm -rf -- "$STAGING"; fi
    fi
    rm -f -- "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$LOCK/pid"
STAGING="$(mktemp -d "$ROOT/dist/.picedit-build.XXXXXX")"
mkdir -p "$BUILD_PATH/ModuleCache" "$BUILD_PATH/IconModuleCache"
BUILD_ARGS=(--disable-sandbox --package-path "$ROOT" --configuration "$CONFIGURATION" --scratch-path "$BUILD_PATH" --jobs "$COMPILER_JOBS")
if [[ -n "${PICEDIT_BUILD_SYSTEM:-}" ]]; then
    BUILD_ARGS+=(--build-system "$PICEDIT_BUILD_SYSTEM")
fi

APP="$STAGING/PicEdit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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
build_product() {
    swift build "${BUILD_ARGS[@]}" --product PicEdit
}
create_icon() {
    # Independent, persistent caches prevent compiler/icon workers contending
    # for the same module files and avoid recompiling imports on every build.
    export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/IconModuleCache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/IconModuleCache"
    swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$ROOT/scripts/make-app-icon.swift" "$ROOT/Assets/AppIcon.png" "$ICONSET"
    iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
}
wait_for_worker() {
    local worker="$1"
    local label="$2"
    local result
    if wait "$worker"; then return 0; else result=$?; fi
    echo "$label failed (exit $result); the existing app is unchanged." >&2
    exit "$result"
}

# Bash 3.2 on macOS supports job-control groups. They let the cleanup trap
# terminate a worker and its descendants without signaling unrelated builds.
set -m
echo "Build budget: $JOB_BUDGET workers ($COMPILER_JOBS compiler jobs; icon generation $([[ "$JOB_BUDGET" == 1 ]] && echo sequential || echo parallel))."
build_product &
COMPILE_PID=$!
if (( JOB_BUDGET > 1 )); then
    create_icon &
    ICON_PID=$!
fi
wait_for_worker "$COMPILE_PID" "Compilation"
COMPILE_PID=""
if [[ -z "$ICON_PID" ]]; then create_icon & ICON_PID=$!; fi
wait_for_worker "$ICON_PID" "Icon generation"
ICON_PID=""
set +m

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_PATH/PicEdit" "$APP/Contents/MacOS/PicEdit"
chmod 755 "$APP/Contents/MacOS/PicEdit"

# SwiftPM dependency and application resources are independent immutable bundles.
# Bundle.module resolves them from the application Resources directory at runtime.
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
    [[ -d "$RESOURCE_BUNDLE" ]] || continue
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
done
plutil -lint "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
fi

# Validation/signing and publication depend on both workers and stay ordered.
# Keep the last good bundle until the new bundle has been moved into place.
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    mv "$DESTINATION" "$STAGING/Previous.app"
fi
mv "$APP" "$DESTINATION"
echo "Built $DESTINATION"
echo "Open it with: open \"$DESTINATION\""

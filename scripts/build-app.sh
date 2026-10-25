#!/bin/bash
set -euo pipefail

# A developer shell must never package a benchmark entry point as the app.
unset GLOWROOM_DEVELOPER_TOOL

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release

case "${1:-}" in
    "") ;;
    --debug) CONFIGURATION=debug ;;
    --help|-h)
        echo "Usage: $0 [--debug]"
        echo "Builds dist/Glowroom.app for the current Mac (release by default)."
        echo "GLOWROOM_BUILD_JOBS=1..1024 overrides the automatic CPU/memory job budget."
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
if [[ -n "${GLOWROOM_BUILD_JOBS+x}" ]]; then
    if [[ ! "$GLOWROOM_BUILD_JOBS" =~ ^[1-9][0-9]{0,3}$ ]] || (( GLOWROOM_BUILD_JOBS > 1024 )); then
        echo "GLOWROOM_BUILD_JOBS must be an integer between 1 and 1024." >&2
        exit 2
    fi
    JOB_BUDGET="$GLOWROOM_BUILD_JOBS"
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

BUILD_PATH="${GLOWROOM_BUILD_PATH:-"$ROOT/.build"}"
if [[ "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$ROOT/$BUILD_PATH"
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$ROOT/dist"
LOCK="$ROOT/dist/.glowroom-build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Another bundle build owns $LOCK (PID: $(cat "$LOCK/pid" 2>/dev/null || echo unknown))." >&2
    echo "Wait for it to finish. After a crash, remove this lock only if its owner is no longer running." >&2
    exit 1
fi
STAGING=""
COMPILE_PID=""
ICON_PID=""
COMPILE_IDENTITY=""
ICON_IDENTITY=""
DESTINATION="$ROOT/dist/Glowroom.app"

# SwiftPM may give clang/Metal children their own process groups. Record birth
# metadata rather than relying on a process group, command name or build path.
# LC_ALL fixes ps's date representation; UID is part of the fingerprint too.
process_identity() {
    LC_ALL=C /bin/ps -p "$1" -o lstart=,uid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}
process_snapshot() {
    LC_ALL=C /bin/ps -axo pid=,ppid=,state=,lstart=,uid= 2>/dev/null |
        /usr/bin/awk '{$1=$1; print}'
}
require_process_inspection() {
    local expected snapshot pid parent state identity
    expected="$(process_identity "$$")" || return 1
    [[ -n "$expected" ]] || return 1
    snapshot="$(process_snapshot)" || return 1
    while read -r pid parent state identity; do
        if [[ "$pid" == "$$" && "$identity" == "$expected" && "$state" != Z* ]]; then return 0; fi
    done <<< "$snapshot"
    return 1
}
freeze_process() {
    local pid="$1" expected="$2" metadata state identity attempt
    [[ "$(process_identity "$pid")" == "$expected" ]] || return 1
    kill -STOP "$pid" 2>/dev/null || return 1
    for ((attempt = 0; attempt < 50; attempt++)); do
        metadata="$(LC_ALL=C /bin/ps -p "$pid" -o state=,lstart=,uid= 2>/dev/null |
            /usr/bin/awk '{$1=$1; print}')" || return 1
        read -r state identity <<< "$metadata"
        [[ "$identity" == "$expected" && "$state" != Z* ]] || return 1
        [[ "$state" != T* ]] || return 0
        sleep 0.01
    done
    return 1
}
capture_owned_workers() {
    local snapshot pid parent state identity index found round changed worker expected
    local complete=1
    # These arrays and count are scoped by stop_owned_workers. Keeping partial
    # capture data lets that caller terminate verified processes even if a later
    # generation cannot be proven complete.
    # A worker waits for its launch file until its identity has been recorded.
    # Thus cancellation during startup cannot lose a newly spawned compiler.
    for worker in "$COMPILE_PID" "$ICON_PID"; do
        [[ -n "$worker" ]] || continue
        if [[ "$worker" == "$COMPILE_PID" ]]; then expected="$COMPILE_IDENTITY"; else expected="$ICON_IDENTITY"; fi
        snapshot="$(process_snapshot)" || return 1
        found=0
        while read -r pid parent state identity; do
            [[ "$pid" == "$worker" && "$parent" == "$$" ]] || continue
            if [[ -n "$expected" && "$identity" != "$expected" ]]; then complete=0; continue; fi
            if [[ "$state" == Z* ]]; then complete=0; continue; fi
            found=1
            owned_pids[count]="$pid"
            owned_identities[count]="$identity"
            count=$((count + 1))
            # Freeze parents before discovering children so they cannot fork or
            # exit and reparent their children while the tree is being captured.
            freeze_process "$pid" "$identity" || return 1
        done <<< "$snapshot"
        # An active recorded root that has disappeared may have orphaned its
        # descendants. Only successful waits explicitly clear recorded roots.
        (( found != 0 )) || complete=0
    done
    if (( count == 0 )); then (( complete == 1 )); return; fi

    # Descendant discovery is deliberately serial: each frozen generation makes
    # the next snapshot stable, including descendants that escaped job control.
    for ((round = 0; round < 64; round++)); do
        changed=0
        snapshot="$(process_snapshot)" || return 1
        while read -r pid parent state identity; do
            found=0
            for ((index = 0; index < count; index++)); do
                if [[ "$pid" == "${owned_pids[index]}" ]]; then found=1; break; fi
            done
            (( found == 0 )) || continue
            for ((index = 0; index < count; index++)); do
                [[ "$parent" == "${owned_pids[index]}" ]] || continue
                # A zombie may already have reparented its children to PID 1.
                [[ "$state" != Z* ]] || return 1
                # Recheck the parent's birth before accepting this ancestry.
                [[ "$(process_identity "$parent")" == "${owned_identities[index]}" ]] || return 1
                # A child that disappears before it can be frozen might have
                # reparented grandchildren; do not claim a complete tree then.
                [[ "$(process_identity "$pid")" == "$identity" ]] || return 1
                (( count < 4096 )) || return 1
                owned_pids[count]="$pid"
                owned_identities[count]="$identity"
                count=$((count + 1))
                freeze_process "$pid" "$identity" || return 1
                changed=1
                break
            done
        done <<< "$snapshot"
        (( changed != 0 )) || break
    done
    (( changed == 0 )) || return 1
    (( complete == 1 ))
}
stop_owned_workers() {
    local snapshot pid parent state identity index found round signal
    local owned_pids=() owned_identities=()
    local count=0 complete=0
    if capture_owned_workers; then complete=1; fi
    if (( count == 0 )); then (( complete == 1 )); return; fi

    # Keep the tree stopped throughout termination: resuming an arbitrary
    # compiler signal handler would reopen the fork/reparent race. TERM records
    # cancellation; KILL then guarantees a TERM-ignoring child cannot write on.
    for signal in TERM KILL; do
        for ((index = count - 1; index >= 0; index--)); do
            pid="${owned_pids[index]}"
            if [[ "$(process_identity "$pid")" == "${owned_identities[index]}" ]]; then
                kill -"$signal" "$pid" 2>/dev/null || true
            fi
        done
    done
    # A zombie cannot write; wait below reaps our direct children. Never signal
    # a PID again after KILL, even if a new process has since reused its number.
    for ((round = 0; round < 100; round++)); do
        snapshot="$(process_snapshot)" || return 1
        found=0
        while read -r pid parent state identity; do
            [[ "$state" != Z* ]] || continue
            for ((index = 0; index < count; index++)); do
                if [[ "$pid" == "${owned_pids[index]}" && "$identity" == "${owned_identities[index]}" ]]; then found=1; break; fi
            done
        done <<< "$snapshot"
        if (( found == 0 )); then (( complete == 1 )); return; fi
        sleep 0.05
    done
    return 1
}
cleanup() {
    local result=$?
    local worker
    local keep_staging=0
    trap - EXIT
    trap '' INT TERM
    if ! stop_owned_workers; then
        echo "Could not verify that all owned build processes stopped; retaining $LOCK and $STAGING." >&2
        echo "Do not clean the build directories until the remaining processes have been checked." >&2
        (( result != 0 )) || result=1
        exit "$result"
    fi
    for worker in "$COMPILE_PID" "$ICON_PID"; do
        if [[ -n "$worker" ]]; then
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
if ! require_process_inspection; then
    echo "Local process inspection is required before build workers can start. Run the build with process-inspection permission." >&2
    exit 1
fi
printf '%s\n' "$$" > "$LOCK/pid"
STAGING="$(mktemp -d "$ROOT/dist/.glowroom-build.XXXXXX")"
mkdir -p "$BUILD_PATH/ModuleCache" "$BUILD_PATH/IconModuleCache"
BUILD_ARGS=(--disable-sandbox --package-path "$ROOT" --configuration "$CONFIGURATION" --scratch-path "$BUILD_PATH" --jobs "$COMPILER_JOBS")
# The pinned, version-matched Metal library is prepared separately so CLT-only
# machines can produce the same functional bundle without a Metal compiler.
BUILD_ARGS+=(--build-system "${GLOWROOM_BUILD_SYSTEM:-native}")

APP="$STAGING/Glowroom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleDisplayName</key><string>Glowroom</string>
    <key>CFBundleExecutable</key><string>Glowroom</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>de.wolfgangbauer.glowroom</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Glowroom</string>
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
await_worker_launch() {
    local launch_file="$1" deadline=$((SECONDS + 10))
    # A failed identity lookup can leave the parent unable to prove cleanup.
    # An unadmitted worker must nevertheless stop itself instead of waiting
    # forever for a launch file its failed parent may never publish.
    while [[ ! -f "$launch_file" ]]; do
        if (( SECONDS >= deadline )); then
            echo "Worker launch was not admitted within 10 seconds." >&2
            return 1
        fi
        sleep 0.01
    done
}
build_product() {
    await_worker_launch "$STAGING/compile.start" || return 1
    "$ROOT/scripts/prepare-mlx-runtime.sh" "$BUILD_PATH/MLXRuntime"
    swift build "${BUILD_ARGS[@]}" --product Glowroom
    # Both products share SwiftPM state, so their builds stay ordered. The MCP
    # adapter reuses the already compiled core and has no MLX dependency itself.
    swift build "${BUILD_ARGS[@]}" --product GlowroomMCP
}
create_icon() {
    await_worker_launch "$STAGING/icon.start" || return 1
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

# Job control preserves normal interactive compiler behavior. Cancellation uses
# the verified descendant tree instead, because native tools can leave a group.
set -m
echo "Build budget: $JOB_BUDGET workers ($COMPILER_JOBS compiler jobs; icon generation $([[ "$JOB_BUDGET" == 1 ]] && echo sequential || echo parallel))."
build_product &
COMPILE_PID=$!
COMPILE_IDENTITY="$(process_identity "$COMPILE_PID")"
[[ -n "$COMPILE_IDENTITY" ]] || { echo "Cannot identify the compiler worker." >&2; exit 1; }
touch "$STAGING/compile.start"
if (( JOB_BUDGET > 1 )); then
    create_icon &
    ICON_PID=$!
    ICON_IDENTITY="$(process_identity "$ICON_PID")"
    [[ -n "$ICON_IDENTITY" ]] || { echo "Cannot identify the icon worker." >&2; exit 1; }
    touch "$STAGING/icon.start"
fi
wait_for_worker "$COMPILE_PID" "Compilation"
COMPILE_PID=""
if [[ -z "$ICON_PID" ]]; then
    create_icon &
    ICON_PID=$!
    ICON_IDENTITY="$(process_identity "$ICON_PID")"
    [[ -n "$ICON_IDENTITY" ]] || { echo "Cannot identify the icon worker." >&2; exit 1; }
    touch "$STAGING/icon.start"
fi
wait_for_worker "$ICON_PID" "Icon generation"
ICON_PID=""
set +m

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_PATH/Glowroom" "$APP/Contents/MacOS/Glowroom"
cp "$BIN_PATH/GlowroomMCP" "$APP/Contents/MacOS/GlowroomMCP"
cp "$BUILD_PATH/MLXRuntime/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
cp "$BUILD_PATH/MLXRuntime/MLX-LICENSE.txt" "$APP/Contents/Resources/MLX-LICENSE.txt"
chmod 755 "$APP/Contents/MacOS/Glowroom"
chmod 755 "$APP/Contents/MacOS/GlowroomMCP"

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

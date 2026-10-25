#!/bin/bash
set -euo pipefail

# Exercise build orchestration without compiling Swift or replacing the user's app.
# Fixtures have independent roots, caches, mock tools and publication directories.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Fail before creating fixtures or forking a build when the caller cannot prove
# ownership for cleanup (for example, a sandbox that denies ps).
if [[ -z "$(LC_ALL=C /bin/ps -p "$$" -o lstart=,uid= 2>/dev/null || true)" ]] ||
   ! LC_ALL=C /bin/ps -axo pid=,ppid=,state=,lstart=,uid= >/dev/null 2>&1; then
    echo "Build orchestration tests require local process-inspection permission; no fixtures or workers were started." >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/glowroom-build-tests.XXXXXX")"
ACTIVE_PID=""
ACTIVE_IDENTITY=""
SENTINEL_PID=""
SENTINEL_IDENTITY=""
ORPHAN_PID=""
ORPHAN_IDENTITY=""
fixture_identity() {
    LC_ALL=C /bin/ps -p "$1" -o lstart=,uid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}
signal_fixture() {
    local pid="$1" identity="$2" signal="$3"
    [[ -n "$pid" && -n "$identity" ]] || return 0
    if [[ "$(fixture_identity "$pid")" == "$identity" ]]; then kill -"$signal" "$pid" 2>/dev/null || true; fi
}
cleanup() {
    local result=$? snapshot pid state command unsafe=0
    if [[ -n "$ACTIVE_PID" ]]; then
        signal_fixture "$ACTIVE_PID" "$ACTIVE_IDENTITY" TERM
        wait "$ACTIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "$SENTINEL_PID" ]]; then
        signal_fixture "$SENTINEL_PID" "$SENTINEL_IDENTITY" KILL
        wait "$SENTINEL_PID" 2>/dev/null || true
    fi
    signal_fixture "$ORPHAN_PID" "$ORPHAN_IDENTITY" KILL
    # Paths are used only to conservatively retain data, never to select a
    # process to signal. Unknown/live workers must keep their fixture intact.
    if snapshot="$(LC_ALL=C /bin/ps -axo pid=,state=,command= 2>/dev/null)"; then
        while read -r pid state command; do
            if [[ "$state" != Z* && "$command" == *"$TEST_ROOT/"* ]]; then unsafe=1; break; fi
        done <<< "$snapshot"
    else unsafe=1
    fi
    if (( unsafe != 0 )); then
        echo "Retaining $TEST_ROOT because test-worker termination could not be verified." >&2
        (( result != 0 )) || result=1
    else rm -rf -- "$TEST_ROOT"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

MOCK_TOOLS="$TEST_ROOT/tools"
mkdir -p "$MOCK_TOOLS"
cat > "$MOCK_TOOLS/mock-tool" <<'MOCK'
#!/bin/bash
set -euo pipefail
tool="${0##*/}"
wait_for() {
    local attempt
    for ((attempt = 0; attempt < 250; attempt++)); do
        [[ ! -f "$1" ]] || return 0
        sleep 0.02
    done
    echo "Timed out waiting for $1" >&2
    return 1
}
case "$tool" in
    sysctl)
        if [[ "${MOCK_SYSCTL_FAILURE:-0}" == 1 ]]; then exit 1; fi
        case "$*" in
            *hw.memsize*) echo "${MOCK_MEMORY_BYTES:-8589934592}" ;;
            *hw.*cpu*) echo "${MOCK_CPU_COUNT:-8}" ;;
            *) exit 1 ;;
        esac
        ;;
    swift)
        [[ -z "${GLOWROOM_DEVELOPER_TOOL+x}" ]] || { echo "Developer harness leaked into app build" >&2; exit 1; }
        if [[ "${1:-}" == build ]]; then
            role=compile
            show_bin=0
            jobs=""
            previous=""
            for argument in "$@"; do
                [[ "$argument" != --show-bin-path ]] || show_bin=1
                if [[ "$previous" == --jobs || "$previous" == -j ]]; then jobs="$argument"; fi
                previous="$argument"
            done
            if [[ "$show_bin" == 1 ]]; then echo "$MOCK_ROOT/bin"; exit 0; fi
            [[ -n "$jobs" ]] || { echo "Missing --jobs" >&2; exit 1; }
            echo "$jobs" > "$MOCK_ROOT/compiler-jobs"
            printf '%s\n%s\n' "${CLANG_MODULE_CACHE_PATH:-}" "${SWIFTPM_MODULECACHE_OVERRIDE:-}" > "$MOCK_ROOT/compile-cache"
        else
            role=icon
            previous=""
            for argument in "$@"; do
                if [[ "$previous" == -module-cache-path ]]; then echo "$argument" > "$MOCK_ROOT/icon-cache-argument"; fi
                previous="$argument"
            done
            printf '%s\n%s\n' "${CLANG_MODULE_CACHE_PATH:-}" "${SWIFTPM_MODULECACHE_OVERRIDE:-}" > "$MOCK_ROOT/icon-cache"
        fi
        echo "$$" > "$MOCK_ROOT/$role.pid"
        touch "$MOCK_ROOT/$role.started"
        case "$MOCK_MODE" in
            parallel)
                if [[ "$role" == compile ]]; then wait_for "$MOCK_ROOT/icon.started"; else wait_for "$MOCK_ROOT/compile.started"; fi
                ;;
            serial)
                mkdir "$MOCK_ROOT/worker-active" || { echo "Workers overlap with a one-job budget" >&2; exit 1; }
                sleep 0.1
                rmdir "$MOCK_ROOT/worker-active"
                ;;
            fail-compile) [[ "$role" != compile ]] || exit 41 ;;
            fail-icon) [[ "$role" != icon ]] || exit 42 ;;
            fail-orphan)
                if [[ "$role" == compile ]]; then
                    set -m
                    (trap '' TERM; exec sleep 300) &
                    echo "$!" > "$MOCK_ROOT/orphan.pid"
                    LC_ALL=C /bin/ps -p "$!" -o lstart=,uid= | /usr/bin/awk '{$1=$1; print}' > "$MOCK_ROOT/orphan.identity"
                    exit 41
                fi
                ;;
            hold)
                sleep 30 &
                child=$!
                echo "$child" > "$MOCK_ROOT/$role.child.pid"
                wait "$child"
                ;;
            hold-escaped)
                # Both generations escape the build worker's process group.
                # Ignoring TERM is inherited by sleep, so group TERM alone
                # cannot satisfy this cancellation fixture.
                set -m
                (
                    trap '' TERM
                    sleep 30 &
                    grandchild=$!
                    echo "$grandchild" > "$MOCK_ROOT/$role.grandchild.pid"
                    wait "$grandchild"
                ) &
                child=$!
                echo "$child" > "$MOCK_ROOT/$role.child.pid"
                wait "$child"
                ;;
        esac
        if [[ "$role" == compile ]]; then
            mkdir -p "$MOCK_ROOT/bin"
            printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/bin/Glowroom"
            printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/bin/GlowroomMCP"
            mkdir -p "$MOCK_ROOT/bin/Glowroom_Glowroom.bundle/nested" "$MOCK_ROOT/bin/Tokenizer Resources.bundle"
            printf 'approved manifest fixture\n' > "$MOCK_ROOT/bin/Glowroom_Glowroom.bundle/nested/manifest.json"
            printf 'dependency resource fixture\n' > "$MOCK_ROOT/bin/Tokenizer Resources.bundle/data.txt"
        else
            mkdir -p "${!#}"
        fi
        touch "$MOCK_ROOT/$role.finished"
        ;;
    iconutil)
        output=""
        previous=""
        for argument in "$@"; do
            if [[ "$previous" == --output ]]; then output="$argument"; fi
            previous="$argument"
        done
        [[ -n "$output" ]] || exit 1
        printf 'mock icon\n' > "$output"
        touch "$MOCK_ROOT/iconutil.finished"
        ;;
    plutil|codesign)
        [[ -f "$MOCK_ROOT/compile.finished" && -f "$MOCK_ROOT/iconutil.finished" ]] || {
            echo "$tool ran before both workers completed" >&2
            exit 1
        }
        if [[ "$tool" == codesign && "$MOCK_MODE" == fail-sign ]]; then exit 43; fi
        touch "$MOCK_ROOT/$tool.finished"
        ;;
    mv)
        if [[ "$MOCK_MODE" == fail-publish && "${1:-}" == */dist/.glowroom-build.*/Glowroom.app && "${2:-}" == */dist/Glowroom.app ]]; then
            touch "$MOCK_ROOT/publish.failed"
            echo "Simulated failure publishing the new app" >&2
            exit 44
        fi
        exec /bin/mv "$@"
        ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCK_TOOLS/mock-tool"
for tool in swift iconutil plutil codesign sysctl mv; do ln -s mock-tool "$MOCK_TOOLS/$tool"; done

new_case() {
    CASE="$TEST_ROOT/$1"
    mkdir -p "$CASE/scripts" "$CASE/dist/Glowroom.app"
    cp "$ROOT/scripts/build-app.sh" "$CASE/scripts/build-app.sh"
    cat > "$CASE/scripts/prepare-mlx-runtime.sh" <<'MOCKRUNTIME'
#!/bin/bash
mkdir -p "$1"
printf 'verified shader fixture\n' > "$1/mlx.metallib"
printf 'MLX license fixture\n' > "$1/MLX-LICENSE.txt"
MOCKRUNTIME
    chmod +x "$CASE/scripts/prepare-mlx-runtime.sh"
    touch "$CASE/scripts/make-app-icon.swift"
    printf 'previous app\n' > "$CASE/dist/Glowroom.app/previous"
}
run_build() {
    env PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE="$1" \
        GLOWROOM_DEVELOPER_TOOL=editing \
        GLOWROOM_BUILD_PATH="$CASE/cache" GLOWROOM_BUILD_JOBS="$2" \
        /bin/bash "$CASE/scripts/build-app.sh" > "${3:-"$CASE/output.log"}" 2>&1
}
assert_clean() {
    local leftover
    for leftover in "$CASE/dist"/.glowroom-build.*; do
        [[ ! -e "$leftover" && ! -L "$leftover" ]] || fail "Build left $leftover"
    done
}
assert_previous_app() {
    [[ -f "$CASE/dist/Glowroom.app/previous" ]] || fail "Previous app lost in $CASE"
    [[ "$(cat "$CASE/dist/Glowroom.app/previous")" == 'previous app' ]] || fail "Previous app changed"
}
assert_retained() {
    local leftover found=0
    [[ -d "$CASE/dist/.glowroom-build.lock" ]] || fail "Unproven worker cleanup released the lock"
    for leftover in "$CASE/dist"/.glowroom-build.??????; do
        [[ ! -d "$leftover" ]] || found=1
    done
    (( found == 1 )) || fail "Unproven worker cleanup removed staging"
    [[ -f "$CASE/output.log" ]] && /usr/bin/grep -q 'Could not verify' "$CASE/output.log" || fail "Incomplete process proof was not reported"
}
assert_success() {
    [[ -x "$CASE/dist/Glowroom.app/Contents/MacOS/Glowroom" ]] || fail "Missing executable"
    [[ -x "$CASE/dist/Glowroom.app/Contents/MacOS/GlowroomMCP" ]] || fail "Missing MCP adapter"
    [[ -f "$CASE/dist/Glowroom.app/Contents/Resources/AppIcon.icns" ]] || fail "Missing icon"
    cmp "$CASE/bin/Glowroom_Glowroom.bundle/nested/manifest.json" "$CASE/dist/Glowroom.app/Contents/Resources/Glowroom_Glowroom.bundle/nested/manifest.json" || fail "Application resources changed or missing"
    cmp "$CASE/bin/Tokenizer Resources.bundle/data.txt" "$CASE/dist/Glowroom.app/Contents/Resources/Tokenizer Resources.bundle/data.txt" || fail "Dependency resources changed or missing"
    [[ -s "$CASE/dist/Glowroom.app/Contents/Resources/mlx.metallib" ]] || fail "Qwen Metal runtime missing"
    [[ -s "$CASE/dist/Glowroom.app/Contents/Resources/MLX-LICENSE.txt" ]] || fail "MLX license missing"
    [[ ! -e "$CASE/dist/Glowroom.app/previous" ]] || fail "Previous app was not replaced"
    [[ -f "$CASE/codesign.finished" ]] || fail "Signing was skipped"
    assert_clean
}
wait_for_file() {
    local attempt
    for ((attempt = 0; attempt < 250; attempt++)); do
        [[ ! -f "$1" ]] || return 0
        sleep 0.02
    done
    fail "Timed out waiting for $1"
}

new_case process-inspection-denied
cat > "$CASE/deny-ps" <<'MOCKPS'
#!/bin/sh
exit 1
MOCKPS
chmod +x "$CASE/deny-ps"
sed "s|/bin/ps|$CASE/deny-ps|g" "$CASE/scripts/build-app.sh" > "$CASE/scripts/build-app-denied.sh"
mv "$CASE/scripts/build-app-denied.sh" "$CASE/scripts/build-app.sh"
if run_build parallel 4; then fail "Started a build without process-inspection permission"; fi
/usr/bin/grep -q 'process inspection is required before build workers' "$CASE/output.log" || fail "Missing process-inspection preflight diagnostic"
[[ ! -f "$CASE/compile.started" && ! -f "$CASE/icon.started" ]] || fail "Started workers before process-inspection preflight"
assert_previous_app
assert_clean
pass "Unavailable process inspection fails before any build worker is launched"

new_case unadmitted-worker
# Fault injection affects only this copied fixture: inspection succeeds for the
# parent preflight but fails for the just-forked worker. Shorten its real bounded
# admission wait so this regression stays quick without changing production.
sed -e '/^process_identity() {/a\
    [[ "$1" == "$$" ]] || return 1
' -e 's/deadline=$((SECONDS + 10))/deadline=$((SECONDS + 1))/' \
    -e '/^COMPILE_PID=\$!$/a\
printf "%s\\n" "$COMPILE_PID" > "$ROOT/unadmitted.pid"
' "$CASE/scripts/build-app.sh" > "$CASE/scripts/build-app-unadmitted.sh"
mv "$CASE/scripts/build-app-unadmitted.sh" "$CASE/scripts/build-app.sh"
if run_build parallel 4; then fail "Ignored failed worker identity admission"; fi
wait_for_file "$CASE/unadmitted.pid"
ORPHAN_PID="$(cat "$CASE/unadmitted.pid")"
ORPHAN_IDENTITY="$(fixture_identity "$ORPHAN_PID" || true)"
for ((attempt = 0; attempt < 250; attempt++)); do
    [[ -n "$ORPHAN_IDENTITY" && "$(fixture_identity "$ORPHAN_PID")" == "$ORPHAN_IDENTITY" ]] || break
    sleep 0.02
done
if [[ -n "$ORPHAN_IDENTITY" && "$(fixture_identity "$ORPHAN_PID")" == "$ORPHAN_IDENTITY" ]]; then fail "Unadmitted worker waited indefinitely for its launch file"; fi
ORPHAN_PID=""; ORPHAN_IDENTITY=""
assert_previous_app
assert_retained
pass "Unadmitted workers expire their launch wait even when process proof fails"

new_case parallel
run_build parallel 4 || { cat "$CASE/output.log" >&2; fail "Parallel build failed"; }
[[ "$(cat "$CASE/compiler-jobs")" == 3 ]] || fail "Four-job budget did not reserve one job for icons"
[[ "$(head -n 1 "$CASE/compile-cache")" == "$CASE/cache/ModuleCache" ]] || fail "Unexpected compiler cache"
[[ "$(head -n 1 "$CASE/icon-cache")" == "$CASE/cache/IconModuleCache" ]] || fail "Icon cache is not isolated"
[[ "$(tail -n 1 "$CASE/icon-cache")" == "$CASE/cache/IconModuleCache" ]] || fail "Icon SwiftPM cache is not isolated"
[[ "$(cat "$CASE/icon-cache-argument")" == "$CASE/cache/IconModuleCache" ]] || fail "Icon compiler cache argument is not isolated"
assert_success
pass "Workers overlap; four-job budget uses three compiler jobs and an isolated icon cache"

new_case serial
run_build serial 1 || { cat "$CASE/output.log" >&2; fail "Serial build failed"; }
[[ "$(cat "$CASE/compiler-jobs")" == 1 ]] || fail "One-job budget changed"
assert_success
pass "One-job budget keeps workers serial"

new_case automatic
env -u GLOWROOM_BUILD_JOBS PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE=parallel \
    MOCK_CPU_COUNT=8 MOCK_MEMORY_BYTES=8589934592 GLOWROOM_BUILD_PATH="$CASE/cache" \
    /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1 || {
        cat "$CASE/output.log" >&2; fail "Automatic job selection failed"
    }
[[ "$(cat "$CASE/compiler-jobs")" == 3 ]] || fail "Automatic job budget ignored the memory bound"
assert_success
pass "Automatic job budget respects available CPU and memory"

new_case fallback
env -u GLOWROOM_BUILD_JOBS PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE=serial \
    MOCK_SYSCTL_FAILURE=1 GLOWROOM_BUILD_PATH="$CASE/cache" \
    /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1 || {
        cat "$CASE/output.log" >&2; fail "Hardware-query fallback failed"
    }
[[ "$(cat "$CASE/compiler-jobs")" == 1 ]] || fail "Unavailable hardware information should use one job"
assert_success
pass "Missing hardware information falls back to one job"

case_number=0
for invalid in 0 -1 abc 1.5 1025 999999999999999999999999; do
    case_number=$((case_number + 1))
    new_case "invalid-$case_number"
    if run_build parallel "$invalid"; then fail "Accepted invalid job budget $invalid"; fi
    [[ ! -f "$CASE/compile.started" && ! -f "$CASE/icon.started" ]] || fail "Started work with invalid budget $invalid"
    assert_previous_app
    assert_clean
done
pass "Invalid job budgets are rejected before work starts"

for failure in fail-compile fail-icon; do
    new_case "$failure"
    if run_build "$failure" 4; then fail "Ignored $failure"; fi
    assert_previous_app
    assert_retained
done
pass "Failed worker waits preserve the previous app, lock and staging for verified manual cleanup"

new_case fail-sign
if run_build fail-sign 4; then fail "Ignored fail-sign"; fi
assert_previous_app
assert_clean
pass "Signing failure after successful worker waits preserves the previous app and cleans staging"

new_case fail-orphan
if run_build fail-orphan 4; then fail "Ignored an orphaning compiler failure"; fi
ORPHAN_PID="$(cat "$CASE/orphan.pid")"
ORPHAN_IDENTITY="$(cat "$CASE/orphan.identity")"
[[ "$(fixture_identity "$ORPHAN_PID")" == "$ORPHAN_IDENTITY" ]] || fail "Orphan fixture did not survive its compiler parent"
assert_previous_app
assert_retained
signal_fixture "$ORPHAN_PID" "$ORPHAN_IDENTITY" KILL
ORPHAN_PID=""
ORPHAN_IDENTITY=""
pass "An exited worker with an escaped live orphan cannot release the build lock or staging"

new_case fail-publish
if run_build fail-publish 4; then fail "Ignored a publication failure"; fi
[[ -f "$CASE/codesign.finished" ]] || fail "Publication fixture did not reach a fully signed bundle"
[[ -f "$CASE/publish.failed" ]] || fail "Publication fixture did not simulate the move failure"
assert_previous_app
assert_clean
pass "Publication failure restores the previous app and removes staging"

check_cancellation() {
local mode="$1"
local status pid_file worker_pid attempt worker_group descendant_group
new_case "cancellation-$mode"
# Same executable name as the mock compiler's deepest child, but unrelated to
# the build tree. Cancellation must leave it alive, even across process groups.
sleep 300 &
SENTINEL_PID=$!
SENTINEL_IDENTITY="$(fixture_identity "$SENTINEL_PID")"
env PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE="$mode" \
    GLOWROOM_BUILD_PATH="$CASE/cache" GLOWROOM_BUILD_JOBS=4 \
    /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1 &
ACTIVE_PID=$!
ACTIVE_IDENTITY="$(fixture_identity "$ACTIVE_PID")"
wait_for_file "$CASE/compile.child.pid"
wait_for_file "$CASE/icon.child.pid"
if [[ "$mode" == hold-escaped ]]; then
    wait_for_file "$CASE/compile.grandchild.pid"
    wait_for_file "$CASE/icon.grandchild.pid"
    worker_group="$(/bin/ps -p "$(cat "$CASE/compile.pid")" -o pgid= | tr -d ' ')"
    descendant_group="$(/bin/ps -p "$(cat "$CASE/compile.grandchild.pid")" -o pgid= | tr -d ' ')"
    [[ -n "$worker_group" && -n "$descendant_group" && "$worker_group" != "$descendant_group" ]] || fail "Fixture did not escape the worker process group"
fi
if run_build hold 4 "$CASE/second-invocation.log"; then fail "A second invocation acquired the active build lock"; fi
[[ -d "$CASE/dist/.glowroom-build.lock" ]] || fail "Second invocation removed the first build's lock"
signal_fixture "$ACTIVE_PID" "$ACTIVE_IDENTITY" TERM
status=0
wait "$ACTIVE_PID" || status=$?
ACTIVE_PID=""
[[ "$status" == 143 ]] || fail "TERM returned $status instead of 143"
for pid_file in "$CASE"/*.pid; do
    worker_pid="$(cat "$pid_file")"
    for ((attempt = 0; attempt < 250; attempt++)); do
        if ! kill -0 "$worker_pid" 2>/dev/null; then break; fi
        sleep 0.02
    done
    if kill -0 "$worker_pid" 2>/dev/null; then fail "Worker survived cancellation: $worker_pid"; fi
done
assert_previous_app
assert_clean
kill -0 "$SENTINEL_PID" 2>/dev/null || fail "Cancellation killed an unrelated process"
signal_fixture "$SENTINEL_PID" "$SENTINEL_IDENTITY" KILL
wait "$SENTINEL_PID" 2>/dev/null || true
SENTINEL_PID=""
pass "$mode: lock excludes a second invocation; TERM stops only owned descendants and cleans staging"
}
check_cancellation hold
check_cancellation hold-escaped

echo "All local build orchestration checks passed."

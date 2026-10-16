#!/bin/bash
set -euo pipefail

# Exercise build orchestration without compiling Swift or replacing the user's app.
# Fixtures have independent roots, caches, mock tools and publication directories.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picedit-build-tests.XXXXXX")"
ACTIVE_PID=""
cleanup() {
    if [[ -n "$ACTIVE_PID" ]]; then
        kill -TERM "$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
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
        [[ -z "${PICEDIT_DEVELOPER_TOOL+x}" ]] || { echo "Developer harness leaked into app build" >&2; exit 1; }
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
            hold)
                sleep 30 &
                child=$!
                echo "$child" > "$MOCK_ROOT/$role.child.pid"
                wait "$child"
                ;;
        esac
        if [[ "$role" == compile ]]; then
            mkdir -p "$MOCK_ROOT/bin"
            printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/bin/PicEdit"
            mkdir -p "$MOCK_ROOT/bin/PicEdit_PicEdit.bundle/nested" "$MOCK_ROOT/bin/Tokenizer Resources.bundle"
            printf 'approved manifest fixture\n' > "$MOCK_ROOT/bin/PicEdit_PicEdit.bundle/nested/manifest.json"
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
        if [[ "$MOCK_MODE" == fail-publish && "${1:-}" == */dist/.picedit-build.*/PicEdit.app && "${2:-}" == */dist/PicEdit.app ]]; then
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
    mkdir -p "$CASE/scripts" "$CASE/dist/PicEdit.app"
    cp "$ROOT/scripts/build-app.sh" "$CASE/scripts/build-app.sh"
    touch "$CASE/scripts/make-app-icon.swift"
    printf 'previous app\n' > "$CASE/dist/PicEdit.app/previous"
}
run_build() {
    env PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE="$1" \
        PICEDIT_DEVELOPER_TOOL=editing \
        PICEDIT_BUILD_PATH="$CASE/cache" PICEDIT_BUILD_JOBS="$2" \
        /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1
}
assert_clean() {
    local leftover
    for leftover in "$CASE/dist"/.picedit-build.*; do
        [[ ! -e "$leftover" && ! -L "$leftover" ]] || fail "Build left $leftover"
    done
}
assert_previous_app() {
    [[ -f "$CASE/dist/PicEdit.app/previous" ]] || fail "Previous app lost in $CASE"
    [[ "$(cat "$CASE/dist/PicEdit.app/previous")" == 'previous app' ]] || fail "Previous app changed"
}
assert_success() {
    [[ -x "$CASE/dist/PicEdit.app/Contents/MacOS/PicEdit" ]] || fail "Missing executable"
    [[ -f "$CASE/dist/PicEdit.app/Contents/Resources/AppIcon.icns" ]] || fail "Missing icon"
    cmp "$CASE/bin/PicEdit_PicEdit.bundle/nested/manifest.json" "$CASE/dist/PicEdit.app/Contents/Resources/PicEdit_PicEdit.bundle/nested/manifest.json" || fail "Application resources changed or missing"
    cmp "$CASE/bin/Tokenizer Resources.bundle/data.txt" "$CASE/dist/PicEdit.app/Contents/Resources/Tokenizer Resources.bundle/data.txt" || fail "Dependency resources changed or missing"
    [[ ! -e "$CASE/dist/PicEdit.app/previous" ]] || fail "Previous app was not replaced"
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
env -u PICEDIT_BUILD_JOBS PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE=parallel \
    MOCK_CPU_COUNT=8 MOCK_MEMORY_BYTES=8589934592 PICEDIT_BUILD_PATH="$CASE/cache" \
    /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1 || {
        cat "$CASE/output.log" >&2; fail "Automatic job selection failed"
    }
[[ "$(cat "$CASE/compiler-jobs")" == 3 ]] || fail "Automatic job budget ignored the memory bound"
assert_success
pass "Automatic job budget respects available CPU and memory"

new_case fallback
env -u PICEDIT_BUILD_JOBS PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE=serial \
    MOCK_SYSCTL_FAILURE=1 PICEDIT_BUILD_PATH="$CASE/cache" \
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

for failure in fail-compile fail-icon fail-sign; do
    new_case "$failure"
    if run_build "$failure" 4; then fail "Ignored $failure"; fi
    assert_previous_app
    assert_clean
done
pass "Compiler, icon and signing failures preserve the previous app"

new_case fail-publish
if run_build fail-publish 4; then fail "Ignored a publication failure"; fi
[[ -f "$CASE/codesign.finished" ]] || fail "Publication fixture did not reach a fully signed bundle"
[[ -f "$CASE/publish.failed" ]] || fail "Publication fixture did not simulate the move failure"
assert_previous_app
assert_clean
pass "Publication failure restores the previous app and removes staging"

new_case cancellation
env PATH="$MOCK_TOOLS:$PATH" MOCK_ROOT="$CASE" MOCK_MODE=hold \
    PICEDIT_BUILD_PATH="$CASE/cache" PICEDIT_BUILD_JOBS=4 \
    /bin/bash "$CASE/scripts/build-app.sh" > "$CASE/output.log" 2>&1 &
ACTIVE_PID=$!
wait_for_file "$CASE/compile.child.pid"
wait_for_file "$CASE/icon.child.pid"
if run_build hold 4; then fail "A second invocation acquired the active build lock"; fi
[[ -d "$CASE/dist/.picedit-build.lock" ]] || fail "Second invocation removed the first build's lock"
kill -TERM "$ACTIVE_PID"
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
pass "Lock excludes a second invocation; TERM stops workers and descendants and cleans staging"

echo "All local build orchestration checks passed."

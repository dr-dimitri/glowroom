#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/picedit-harness-tests.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
mkdir -p "$STAGING/tools" "$STAGING/checkout/Sources/PicEdit/DeveloperTools"
cat > "$STAGING/tools/xcrun" <<'MOCK'
#!/bin/bash
touch "$PICEDIT_HARNESS_COMPILE_MARKER"
exit 99
MOCK
chmod +x "$STAGING/tools/xcrun"
assert_rejected() {
    local status=0
    env PATH="$STAGING/tools:$PATH" PICEDIT_HARNESS_COMPILE_MARKER="$STAGING/compiled" \
        PICEDIT_TOOL_SOURCE_ROOT="$STAGING/checkout" \
        PICEDIT_DEVELOPER_BUILD_PATH="$STAGING/cache" \
        "$ROOT/scripts/build-developer-tool.sh" editing > "$STAGING/output" 2>&1 || status=$?
    [[ "$status" == 2 && ! -e "$STAGING/compiled" && ! -e "$STAGING/cache" ]] || {
        cat "$STAGING/output" >&2
        echo 'FAIL: unsupported source checkout reached compiler' >&2
        exit 1
    }
}
printf '// older application manifest\n' > "$STAGING/checkout/Package.swift"
assert_rejected
touch "$STAGING/checkout/Sources/PicEdit/DeveloperTools/EditingBenchmark.swift"
assert_rejected
printf '// PICEDIT_DEVELOPER_HARNESS_VERSION: 1\n' > "$STAGING/checkout/Package.swift"
rm "$STAGING/checkout/Sources/PicEdit/DeveloperTools/EditingBenchmark.swift"
assert_rejected
echo 'PASS: incompatible manifest and missing harness rejected before build or execution'

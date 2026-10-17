#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${1:-}"
case "$TOOL" in image-pipeline|editing|library|keychain|image-generation) ;; *) echo "Usage: $0 image-pipeline|editing|library|keychain|image-generation" >&2; exit 2 ;; esac
[[ $# == 1 ]] || { echo "Expected one developer tool name" >&2; exit 2; }
SOURCE_ROOT="${PICEDIT_TOOL_SOURCE_ROOT:-$ROOT}"
case "$TOOL" in
    image-pipeline) HARNESS=ImagePipelineSmoke ;;
    editing) HARNESS=EditingBenchmark ;;
    library) HARNESS=LibraryBenchmark ;;
    keychain) HARNESS=KeychainSmoke ;;
    image-generation) HARNESS=ImageGenerationEvaluation ;;
esac
# Older checkouts ignore the harness selector and would launch the real app.
# Require the explicit harness contract before compiling or executing anything.
if [[ ! -f "$SOURCE_ROOT/Sources/PicEdit/DeveloperTools/$HARNESS.swift" ]] ||
   ! /usr/bin/grep -Fqx '// PICEDIT_DEVELOPER_HARNESS_VERSION: 1' "$SOURCE_ROOT/Package.swift"; then
    echo "Source checkout does not support the selected PicEdit developer harness: $SOURCE_ROOT" >&2
    exit 2
fi
BUILD_PATH="${PICEDIT_DEVELOPER_BUILD_PATH:-$ROOT/.build-app/developer-tools/$TOOL}"
[[ "$BUILD_PATH" == /* ]] || BUILD_PATH="$ROOT/$BUILD_PATH"
JOBS="${PICEDIT_BUILD_JOBS:-4}"
if [[ ! "$JOBS" =~ ^[1-9][0-9]{0,3}$ ]] || (( JOBS > 1024 )); then
    echo "PICEDIT_BUILD_JOBS must be an integer between 1 and 1024." >&2
    exit 2
fi
export PICEDIT_DEVELOPER_TOOL="$TOOL"
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
ARGS=(--disable-sandbox --package-path "$SOURCE_ROOT" --scratch-path "$BUILD_PATH" --configuration release --jobs "$JOBS" --product PicEdit)
# Build output stays visible on stderr; stdout is the one executable path.
# Harness modes use the same SwiftPM sources, resources and pinned dependencies
# as the application. Different scratch paths permit independent builds.
xcrun swift build "${ARGS[@]}" >&2
BIN_PATH="$(xcrun swift build "${ARGS[@]}" --show-bin-path)"
printf '%s\n' "$BIN_PATH/PicEdit"

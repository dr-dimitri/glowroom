#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${PICEDIT_BENCHMARK_SOURCE_ROOT:-$PROJECT_ROOT}"
if [[ -n "${PICEDIT_BENCHMARK_BUILD_PATH:-}" ]]; then
    # Use a different directory for concurrent builds; preserving this directory
    # avoids recompiling system modules during sequential renderer experiments.
    BENCHMARK_DIR="$PICEDIT_BENCHMARK_BUILD_PATH"
    mkdir -p "$BENCHMARK_DIR"
else
    BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/picedit-editing-benchmark.XXXXXX")"
    trap 'rm -rf -- "${BENCHMARK_DIR:?}"' EXIT
fi
TARGET="$(uname -m)-apple-macosx14.0"
export CLANG_MODULE_CACHE_PATH="$BENCHMARK_DIR/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
RENDERER_FLAGS=()
if [[ "${PICEDIT_BENCHMARK_SESSION_API:-0}" == 1 ]]; then
    RENDERER_FLAGS+=(-D EDIT_RENDER_SESSIONS)
fi

# The two compilations depend on one another. All generated files and module
# caches stay in the chosen build directory. Independent builds need separate paths.
xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$SOURCE_ROOT/Sources/CSQLite" \
    -parse-as-library -whole-module-optimization \
    -emit-module -emit-object -module-name PicEditCore \
    -emit-module-path "$BENCHMARK_DIR/PicEditCore.swiftmodule" \
    "$SOURCE_ROOT/Sources/PicEditCore/EditSettings.swift" \
    -o "$BENCHMARK_DIR/PicEditCore.o"

xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    "${RENDERER_FLAGS[@]}" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$SOURCE_ROOT/Sources/CSQLite" \
    -I "$BENCHMARK_DIR" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/AdjustedPreviewPipeline.swift" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/AutoTone.swift" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/EditRenderer.swift" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/ImagePreviewPipeline.swift" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/PreviewDecoder.swift" \
    "$SOURCE_ROOT/Sources/PicEdit/Imaging/PreviewDiskCache.swift" \
    "$PROJECT_ROOT/scripts/benchmark-editing.swift" \
    "$BENCHMARK_DIR/PicEditCore.o" \
    -o "$BENCHMARK_DIR/benchmark-editing"

# Optional immutable executable for repeated measurements of the same build.
if [[ -n "${PICEDIT_BENCHMARK_BINARY_PATH:-}" ]]; then
    cp "$BENCHMARK_DIR/benchmark-editing" "$PICEDIT_BENCHMARK_BINARY_PATH"
fi

# Only a generated bitmap is processed. Core Image needs a normal macOS graphics
# session; a restricted automation sandbox can block the system renderer.
if (( $# )); then
    "$BENCHMARK_DIR/benchmark-editing" "$@"
else
    # Separate processes give each configuration its own renderer initialization
    # and peak RSS. Run serially to avoid distorting GPU/CPU timings by contention.
    for scenario in simple complex; do
        "$BENCHMARK_DIR/benchmark-editing" --scenario "$scenario" --width 2400 --height 1600
        "$BENCHMARK_DIR/benchmark-editing" --scenario "$scenario" --width 400 --height 267
    done
    "$BENCHMARK_DIR/benchmark-editing" --scenario alternating
    "$BENCHMARK_DIR/benchmark-editing" --scenario burst
    "$BENCHMARK_DIR/benchmark-editing" --scenario contention --workers 1
    if [[ "${PICEDIT_BENCHMARK_SESSION_API:-0}" == 1 ]]; then
        "$BENCHMARK_DIR/benchmark-editing" --scenario contention --workers 2
    fi
fi

#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/picedit-editing-benchmark.XXXXXX")"
trap 'rm -rf -- "${BENCHMARK_DIR:?}"' EXIT
TARGET="$(uname -m)-apple-macosx14.0"
export CLANG_MODULE_CACHE_PATH="$BENCHMARK_DIR/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# The two compilations depend on one another. All generated files and module
# caches stay in this run's temporary directory, allowing independent builds.
xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$PROJECT_ROOT/Sources/CSQLite" \
    -parse-as-library -whole-module-optimization \
    -emit-module -emit-object -module-name PicEditCore \
    -emit-module-path "$BENCHMARK_DIR/PicEditCore.swiftmodule" \
    "$PROJECT_ROOT"/Sources/PicEditCore/*.swift \
    -o "$BENCHMARK_DIR/PicEditCore.o"

xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$PROJECT_ROOT/Sources/CSQLite" \
    -I "$BENCHMARK_DIR" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/AdjustedPreviewPipeline.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/AutoTone.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/EditRenderer.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/ImagePreviewPipeline.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/PreviewDecoder.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/PreviewDiskCache.swift" \
    "$PROJECT_ROOT/scripts/benchmark-editing.swift" \
    "$BENCHMARK_DIR/PicEditCore.o" \
    -o "$BENCHMARK_DIR/benchmark-editing"

# Only a generated bitmap is processed. Core Image needs a normal macOS graphics
# session; a restricted automation sandbox can block the system renderer.
"$BENCHMARK_DIR/benchmark-editing"

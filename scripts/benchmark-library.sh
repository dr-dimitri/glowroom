#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$PROJECT_ROOT/.build/ModuleCache}"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/picedit-library-benchmark.XXXXXX")"
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
TARGET="$(uname -m)-apple-macosx14.0"

mkdir -p "$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

# Compile the actual model and core, independently of SwiftPM or a running app.
# The benchmark uses 10,000 synthetic records and its own temporary catalog;
# it never opens the user's library or decodes any original images.
xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CACHE_DIR" \
    -I "$PROJECT_ROOT/Sources/CSQLite" \
    -parse-as-library -whole-module-optimization \
    -emit-module -emit-object -module-name PicEditCore \
    -emit-module-path "$BENCHMARK_DIR/PicEditCore.swiftmodule" \
    "$PROJECT_ROOT"/Sources/PicEditCore/*.swift \
    -o "$BENCHMARK_DIR/PicEditCore.o"

xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CACHE_DIR" \
    -I "$PROJECT_ROOT/Sources/CSQLite" \
    -I "$BENCHMARK_DIR" \
    "$PROJECT_ROOT/Sources/PicEdit/LibraryModel.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/LibraryProjection.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/LibraryCatalogWorker.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/FolderTreeNode.swift" \
    "$PROJECT_ROOT/scripts/benchmark-library.swift" \
    "$BENCHMARK_DIR/PicEditCore.o" \
    -o "$BENCHMARK_DIR/benchmark-library"

"$BENCHMARK_DIR/benchmark-library"

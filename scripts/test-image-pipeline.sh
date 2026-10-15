#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$PROJECT_ROOT/.build/ModuleCache}"
TEST_BINARY="$PROJECT_ROOT/.build/image-pipeline-smoke"

mkdir -p "$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

# Compile only the preview pipeline: no package dependencies or running app are
# needed. The harness generates and removes its own JPEG and corrupt fixtures.
xcrun swiftc \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$CACHE_DIR" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/ImagePreviewPipeline.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/PreviewDecoder.swift" \
    "$PROJECT_ROOT/Sources/PicEdit/Imaging/PreviewDiskCache.swift" \
    "$PROJECT_ROOT/scripts/ImagePipelineSmoke.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"

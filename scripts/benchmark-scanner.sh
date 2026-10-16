#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/benchmark-scanner.sh [IMAGE_COUNT] [PASSES]
  IMAGE_COUNT: 1–240 synthetic 6000×4000 JPEGs (default: 120, about 532 MB)
  PASSES:      2–10 scans per worker configuration (default: 5)

Compiles the real scanner with -O, generates its own temporary images, then
measures 1 and 4 requested readers in separate processes. Scanner CPU/memory
limits still apply. Reports the first pass, warm median, and peak process RSS.
The OS file cache is not flushed. Results do not characterize RAW decoding.
All generated images and the benchmark executable are removed on exit.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
IMAGE_COUNT="${1:-120}"
PASSES="${2:-5}"
if (( $# > 2 )) || [[ "$IMAGE_COUNT" != <1-240> || "$PASSES" != <2-10> ]]; then
    usage >&2
    exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$PROJECT_ROOT/.build/ModuleCache}"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/picedit-scanner-benchmark.XXXXXX")"
trap 'rm -rf -- "$BENCHMARK_DIR"' EXIT
TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p "$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

xcrun swiftc \
    -O -swift-version 5 -target "$TARGET" \
    -module-cache-path "$CACHE_DIR" -parse-as-library \
    "$PROJECT_ROOT/Sources/PicEditCore/FolderScanner.swift" \
    "$PROJECT_ROOT/Sources/PicEditCore/LibraryModels.swift" \
    "$PROJECT_ROOT/scripts/benchmark-scanner.swift" \
    -o "$BENCHMARK_DIR/benchmark-scanner"

"$BENCHMARK_DIR/benchmark-scanner" prepare "$BENCHMARK_DIR/images" "$IMAGE_COUNT"
# Separate processes keep fixture generation out of peak RSS. Configurations
# run sequentially to avoid competing for CPU and disk during measurement.
"$BENCHMARK_DIR/benchmark-scanner" scan "$BENCHMARK_DIR/images" "$IMAGE_COUNT" 1 "$PASSES"
"$BENCHMARK_DIR/benchmark-scanner" scan "$BENCHMARK_DIR/images" "$IMAGE_COUNT" 4 "$PASSES"

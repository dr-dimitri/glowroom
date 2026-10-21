#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export GLOWROOM_TOOL_SOURCE_ROOT="${GLOWROOM_BENCHMARK_SOURCE_ROOT:-$ROOT}"
export GLOWROOM_DEVELOPER_BUILD_PATH="${GLOWROOM_BENCHMARK_BUILD_PATH:-${GLOWROOM_DEVELOPER_BUILD_PATH:-$ROOT/.build-app/developer-tools/masks}}"
GLOWROOM_BENCHMARK_COMMIT="$(git -C "$GLOWROOM_TOOL_SOURCE_ROOT" rev-parse HEAD)"
GLOWROOM_BENCHMARK_SWIFT_VERSION="$(xcrun swift --version)"
export GLOWROOM_BENCHMARK_COMMIT GLOWROOM_BENCHMARK_SWIFT_VERSION
BINARY="$("$ROOT/scripts/build-developer-tool.sh" editing)"
if (( $# )); then
    "$BINARY" --scenario masks "$@"
else
    # Isolate canvas sizes by process. Measurements remain serial because
    # competing CPU work would distort the comparison and peak process RSS.
    for dimensions in "1024 1024" "4096 2048" "4096 4096"; do
        read -r width height <<< "$dimensions"
        "$BINARY" --scenario masks --width "$width" --height "$height" --iterations 20
    done
fi

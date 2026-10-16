#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PICEDIT_TOOL_SOURCE_ROOT="${PICEDIT_BENCHMARK_SOURCE_ROOT:-$ROOT}"
export PICEDIT_DEVELOPER_BUILD_PATH="${PICEDIT_BENCHMARK_BUILD_PATH:-${PICEDIT_DEVELOPER_BUILD_PATH:-$ROOT/.build-app/developer-tools/editing}}"
BINARY="$("$ROOT/scripts/build-developer-tool.sh" editing)"

# Keep sibling SwiftPM bundles beside a retained measurement executable.
if [[ -n "${PICEDIT_BENCHMARK_BINARY_PATH:-}" ]]; then
    DESTINATION="$PICEDIT_BENCHMARK_BINARY_PATH"
    mkdir -p "$(dirname -- "$DESTINATION")"
    cp "$BINARY" "$DESTINATION"
    for bundle in "$(dirname -- "$BINARY")"/*.bundle; do
        [[ ! -d "$bundle" ]] || cp -R "$bundle" "$(dirname -- "$DESTINATION")/"
    done
fi

if (( $# )); then
    "$BINARY" "$@"
else
    # Separate processes keep renderer initialization and peak RSS comparable.
    # Runs remain serial because concurrent GPU measurements distort timings.
    for scenario in simple complex; do
        "$BINARY" --scenario "$scenario" --width 2400 --height 1600
        "$BINARY" --scenario "$scenario" --width 400 --height 267
    done
    "$BINARY" --scenario alternating
    "$BINARY" --scenario burst
    "$BINARY" --scenario contention --workers 1
    if [[ "${PICEDIT_BENCHMARK_SESSION_API:-0}" == 1 ]]; then
        "$BINARY" --scenario contention --workers 2
    fi
fi

#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${GLOWROOM_MASK_RUST:-0}" != 0 && "${GLOWROOM_MASK_RUST:-0}" != 1 ]]; then
    echo "GLOWROOM_MASK_RUST must be 0 or 1." >&2
    exit 2
fi
export GLOWROOM_TOOL_SOURCE_ROOT="${GLOWROOM_BENCHMARK_SOURCE_ROOT:-$ROOT}"
export GLOWROOM_DEVELOPER_BUILD_PATH="${GLOWROOM_BENCHMARK_BUILD_PATH:-${GLOWROOM_DEVELOPER_BUILD_PATH:-$ROOT/.build-app/developer-tools/masks}}"
GLOWROOM_BENCHMARK_COMMIT="$(git -C "$GLOWROOM_TOOL_SOURCE_ROOT" rev-parse HEAD)"
GLOWROOM_BENCHMARK_SWIFT_VERSION="$(xcrun swift --version)"
export GLOWROOM_BENCHMARK_COMMIT GLOWROOM_BENCHMARK_SWIFT_VERSION
BINARY="$("$ROOT/scripts/build-developer-tool.sh" editing)"
RUST_ARGS=()
if [[ "${GLOWROOM_MASK_RUST:-0}" == 1 ]]; then
    # Explicit opt-in builds a dependency-free prototype. It is never linked,
    # bundled or signed with the production app. Compilation precedes timing.
    export CARGO_TARGET_DIR="${GLOWROOM_MASK_RUST_BUILD_PATH:-$ROOT/.build-app/developer-tools/mask-rust}"
    [[ "$CARGO_TARGET_DIR" == /* ]] || export CARGO_TARGET_DIR="$ROOT/$CARGO_TARGET_DIR"
    if [[ "$(rustc --version)" != "rustc 1.99.1 "* ]] || [[ "$(cargo --version)" != "cargo 1.99.1 "* ]]; then
        echo "The optional prototype requires rustc and cargo 1.99.1 (see rust-toolchain.toml)." >&2
        exit 2
    fi
    cargo build --manifest-path "$ROOT/tools/mask-performance/Cargo.toml" --release --locked --offline >&2
    export GLOWROOM_BENCHMARK_RUST_VERSION="$(rustc --version)"
    RUST_ARGS=(--mask-library "$CARGO_TARGET_DIR/release/libglowroom_mask_performance.dylib")
elif [[ -n "${GLOWROOM_MASK_RUST_LIBRARY:-}" ]]; then
    RUST_ARGS=(--mask-library "$GLOWROOM_MASK_RUST_LIBRARY")
    export GLOWROOM_BENCHMARK_RUST_VERSION="externally provided library; compiler provenance must be recorded separately"
fi

if (( $# )); then
    "$BINARY" --scenario masks "${RUST_ARGS[@]}" "$@"
else
    # Isolate canvas sizes by process. Measurements remain serial because
    # competing CPU work would distort the comparison and peak process RSS.
    for dimensions in "1024 1024" "4096 2048" "4096 4096"; do
        read -r width height <<< "$dimensions"
        "$BINARY" --scenario masks --width "$width" --height "$height" --iterations 20 "${RUST_ARGS[@]}"
    done
fi

#!/bin/bash
set -euo pipefail

unset GLOWROOM_DEVELOPER_TOOL

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${GLOWROOM_TEST_BUILD_PATH:-"$ROOT/.build"}"
if [[ "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$ROOT/$BUILD_PATH"
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

ARGS=(--disable-sandbox --disable-xctest --package-path "$ROOT" --scratch-path "$BUILD_PATH" --build-system "${GLOWROOM_BUILD_SYSTEM:-native}")
"$ROOT/scripts/prepare-mlx-runtime.sh" "$BUILD_PATH/MLXRuntime"
export GLOWROOM_MLX_METALLIB="$BUILD_PATH/MLXRuntime/mlx.metallib"

# Some Command Line Tools releases bundle Swift Testing without automatically
# exposing its macro plugin. Explicit loading is harmless when it is present;
# toolchains without the bundled plugin use their normal discovery mechanism.
SWIFTC="$(xcrun --find swiftc)"
TESTING_PLUGIN="$(dirname -- "$SWIFTC")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]]; then
    ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
# Swift 6.4's native backend does not add the CLT Testing framework search
# path automatically (the Swift Build backend does). Use the toolchain's own
# framework, preserving its matching macros and runtime.
TESTING_FRAMEWORKS="$(dirname -- "$SWIFTC")/../../Library/Developer/Frameworks"
if [[ -d "$TESTING_FRAMEWORKS/Testing.framework" ]]; then
    ARGS+=(-Xswiftc -F -Xswiftc "$TESTING_FRAMEWORKS" -Xlinker -F -Xlinker "$TESTING_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TESTING_FRAMEWORKS")
fi

xcrun swift test "${ARGS[@]}" "$@"

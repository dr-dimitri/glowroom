#!/bin/bash
set -euo pipefail

unset PICEDIT_DEVELOPER_TOOL

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${PICEDIT_TEST_BUILD_PATH:-"$ROOT/.build"}"
if [[ "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$ROOT/$BUILD_PATH"
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

ARGS=(--disable-sandbox --disable-xctest --package-path "$ROOT" --scratch-path "$BUILD_PATH")

# Some Command Line Tools releases bundle Swift Testing without automatically
# exposing its macro plugin. Explicit loading is harmless when it is present;
# toolchains without the bundled plugin use their normal discovery mechanism.
SWIFTC="$(xcrun --find swiftc)"
TESTING_PLUGIN="$(dirname -- "$SWIFTC")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]]; then
    ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi

xcrun swift test "${ARGS[@]}" "$@"

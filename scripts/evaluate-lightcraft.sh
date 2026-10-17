#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 1 ]] || { echo "Usage: $0 NEW_OUTPUT_DIRECTORY [--candidate LC-01|LC-03|LC-04|LC-05] [--real-manifest PATH]" >&2; exit 2; }
OUTPUT="$1"
shift
[[ ! -e "$OUTPUT" ]] || { echo "Output directory already exists: $OUTPUT" >&2; exit 2; }
# This is a specialized scenario of the existing editing harness, not a second
# renderer/build/benchmark implementation. No model or reference engine download.
BINARY="$("$ROOT/scripts/build-developer-tool.sh" editing)"
exec python3 "$ROOT/tools/lightcraft-evaluation/run.py" "$OUTPUT" --binary "$BINARY" "$@"

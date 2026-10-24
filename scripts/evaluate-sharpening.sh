#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 1 ]] || { echo "Usage: $0 NEW_EXTERNAL_OUTPUT_DIRECTORY [--timing] [--scale]" >&2; exit 2; }
OUTPUT="$1"
shift
[[ ! -e "$OUTPUT" ]] || { echo "Output directory already exists: $OUTPUT" >&2; exit 2; }
BINARY="$("$ROOT/scripts/build-developer-tool.sh" editing)"
exec python3 "$ROOT/tools/darktable-sharpen-evaluation/run.py" "$OUTPUT" --binary "$BINARY" "$@"

#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
BINARY="$("$ROOT/scripts/build-developer-tool.sh" library)"
"$BINARY"

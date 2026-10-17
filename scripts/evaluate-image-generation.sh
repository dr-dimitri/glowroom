#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 0 || "${1:-}" == plan ]]; then
    cat <<'PLAN'
Image backend gate: fullNoGo (quality); no product generator is enabled.
No downloads, model load or inference occur in this default mode.
Explicit preparation: python3 scripts/prepare-image-generation-evaluation.py --help
Synthetic contract fixtures: scripts/evaluate-image-generation.sh fixtures --out /tmp/picedit-fixtures
Current compositor replay: scripts/evaluate-image-generation.sh replay --historical reports/image-backend/historical-2026-10-16 --out /tmp/picedit-replay
Opt-in real benchmark (cold + 3 identical warm runs + cancel):
  scripts/evaluate-image-generation.sh benchmark --run --root /tmp/picedit-evaluation --out /tmp/picedit-measurement
Add --all-fixtures for the other six real mask cases. Benchmark execution makes no model/cloud network requests.
The preceding SwiftPM build can fetch pinned package dependencies into its isolated cache.
PLAN
    exit 0
fi
case "$1" in fixtures|replay|benchmark) ;; *) echo "Expected plan, fixtures, replay or benchmark" >&2; exit 2 ;; esac
if [[ "$1" == benchmark && " $* " != *" --run "* ]]; then
    echo "Real inference requires explicit benchmark --run; installation is a separate command." >&2
    exit 2
fi
BINARY="$("$ROOT/scripts/build-developer-tool.sh" image-generation)"
exec "$BINARY" "$@"

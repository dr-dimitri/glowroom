#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 0 || "${1:-}" == plan ]]; then
    cat <<'PLAN'
Image backend gate: fullNoGo (quality); no product generator is enabled.
No downloads, model load or inference occur in this default mode.
Explicit preparation: python3 scripts/prepare-image-generation-evaluation.py --help
SDXL candidate: scripts/evaluate-image-generation.sh sdxl --run --all-fixtures --fixture-archive /tmp/glowroom-fixture-archive --root /tmp/glowroom-sdxl --out /tmp/glowroom-sdxl-probe
Separate LaMa removal-only candidate (no product Go): python3 tools/lama-evaluation/prepare.py --help
  scripts/evaluate-image-generation.sh lama --run --fixture-archive /tmp/glowroom-fixture-archive --root /tmp/glowroom-lama --out /tmp/glowroom-lama-probe
Add --inspect to inspect the downloaded package interface without inference; no fixture archive is needed.
Historical model fixtures/results are no longer included; supply an external archive with the original hashes.
Synthetic contract fixtures: scripts/evaluate-image-generation.sh fixtures --out /tmp/glowroom-fixtures
Current compositor replay: scripts/evaluate-image-generation.sh replay --historical /tmp/glowroom-archived-run --out /tmp/glowroom-replay
Opt-in real benchmark (cold + 3 identical warm runs + cancel):
  scripts/evaluate-image-generation.sh benchmark --run --root /tmp/glowroom-evaluation --out /tmp/glowroom-measurement
Add --all-fixtures for the other six real mask cases. Benchmark execution makes no model/cloud network requests.
The preceding SwiftPM build can fetch pinned package dependencies into its isolated cache.
PLAN
    exit 0
fi
case "$1" in fixtures|replay|benchmark|lama|sdxl) ;; *) echo "Expected plan, fixtures, replay, benchmark, lama or sdxl" >&2; exit 2 ;; esac
RUN=0
for argument in "$@"; do [[ "$argument" != --run ]] || RUN=1; done
if [[ ( "$1" == benchmark || "$1" == lama || "$1" == sdxl ) && "$RUN" == 0 ]]; then
    echo "Model loading requires explicit --run; installation is a separate command." >&2
    exit 2
fi
BINARY="$("$ROOT/scripts/build-developer-tool.sh" image-generation)"
exec "$BINARY" "$@"

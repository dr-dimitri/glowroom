# Synthetic semantic model evidence

The reports are historical observations from 16 October 2026, before production integration. They preserve failed precision/lifecycle variants as well as the selected CPU-only result. Fixed acceptance limits and ground truth were not changed after inference. See the current [product decision](../../docs/SEMANTIC-SEARCH.md) for supported behavior and limitations.

- `isolated-fp32-gate-summary.json` contains every measured lifecycle and unchanged threshold.
- `ISOLATED-FP32-GATE.md` records device, cache distinctions, all PASS/FAIL paths and the narrow `.all` memory reserve.
- `PRECISION-DIAGNOSTICS.md` and its JSON record the rejected mixed-precision conversions and corrected Float32 image tower.
- `raw/*.json.gz` are lossless archives of all five complete isolated lifecycle JSON files, including raw embeddings, 50 query rankings, negative cases, timing samples and RSS stages. `raw-artifact-manifest.json` maps original names to compressed paths and records both SHA256 values. For example, `gzip -dc raw/<name>.json.gz` restores the original bytes.
- `historical` retains the exact original gate/precision scripts, native harness and pinned package dependencies. Their paths reflect the original `/private/tmp/picedit-semantic-gate` research workspace. They are historical source artifacts, not sources built into PicEdit and not a second product runtime. `model-selection-before-download.md` is the earlier metadata-only investigation, whose subsequently resolved open gates are explicitly historical.
- `../../Fixtures/Semantic` contains the exact frozen 30 synthetic drawings and unchanged ground truth, 58 exact token cases, compact PyTorch reference embeddings (model outputs of these fixtures, never model parameters) and their manifest. Additional preprocessing cases do not replace or alter the frozen relevance fixtures.

No checkpoint, model weights, tokenizer vocabulary or converted model is included here. The current developer-only offline converter and approved import-package builder are under `../../scripts/semantic`; their output must match the application-pinned manifest before use. Never substitute historical `.all` results for a fresh integrated-app memory claim.

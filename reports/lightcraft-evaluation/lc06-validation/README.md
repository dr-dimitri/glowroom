# LC-06 validation

Task branch: `codex/lc06-denoise-evaluation`, based on updated remote `main`
`f75a5e131e7de1c674b768c905dfeb9be6e03f43`.

## Commands and evidence

```sh
python3 tools/lightcraft-evaluation/lc06-reference-oracle/generate.py /Users/wolfgangbauer/dev/workspace/lightcraft
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
./scripts/test.sh --jobs 3 --filter 'AlgorithmEvaluation|LightcraftDenoise|EditRendererTests|EditRenderSessionTests|AdjustedPreviewPipelineTests|JPEGExporterTests|AutoToneRendererTests'
PICEDIT_BUILD_JOBS=3 ./scripts/build-developer-tool.sh editing
python3 tools/lightcraft-evaluation/run.py reports/lightcraft-evaluation/lc06-2026-10-18 --binary .build-app/developer-tools/editing/out/Products/Release/PicEdit --candidate LC-06
```

- `oracle.log`: original-Rust regeneration verifies all 40 cases and five
  pinned source hashes. Swift tests consume the committed vectors without Rust.
- `python-tests.log`: all 78 runner tests pass, including 25 LC-06 cases.
- `targeted-tests.log`: all 90 native tests in ten suites pass, covering the
  reference, metrics, resampling, profile/depth/alpha/cancellation, renderer,
  reusable sessions, adjusted-preview scheduling, AutoTone and JPEG export.
- `harness-build.log`: release measurement-binary build succeeds.
- `evaluation.log`: serial comparison progress; the adjacent LC-06 archive
  preserves commands, host metadata, frozen hashes and raw measurements.
- `lc01-smoke-summary.json`: 126 generic comparison records, no control
  failures, specialized LC-03 through LC-06 acceptance routes remain required.
  Duplicate temporary smoke PNGs are not committed.
- `area-variance-analysis.json`: analytical mean sums of squared separable
  area-overlap weights for independent native noise. These show the difference
  between actual fractional-area variance and the upstream `scale²`
  approximation; they are not measured performance or photo evidence.

Native tests and the developer-tool build used separate generated directories
and bounded jobs. They completed before serial timing began. No initial build
or test attempt failed during this task.

## Review

Independent cross-reviews cover the pinned-source reference/oracle, fixtures,
metrics and area resampling, Swift/Python schema, immutable calibration,
independent decisions, timing attribution and registry routing. Before the
measurement, review found two runner gaps: finite scaling evidence must be
explicit, and missing comparison partners must not suppress independent
alpha/hidden-RGB failures. Both were corrected, regression-tested and
independently rechecked before the sources were frozen.

The stage scope explicitly includes intermediate materialization and altered
AutoTone analysis. Negative-Y chroma amplification is verified in the original
Rust, retained as candidate evidence and not concealed by an input clamp.

## Final result and review

- All 90 native tests, 78 Python tests, 40 original-Rust oracle cases and the
  generic LC-01 smoke route pass. The full experiment completes successfully
  with three independently reproduced `no-go` decisions.
- Independent result audits recompute all 48 quality rows, 32 near-zero
  contracts, 54 scaling rows and all decision gates without contradiction.
  All primary quality cases match; six other luminance cases remain unmatched.
- All 186 frozen source hashes and manifest/calibration hashes match the final
  sources. The runner verifies its binary throughout the experiment, and an
  independent audit verifies it again before the required clean build removes
  the measurement binary.
- All 80 timing processes are complete: 80 cold, 80 warmup and 400 warm samples.
  All 280 effect pairs are unmatched; no timing result produces a performance
  veto or an equal-effect gain claim.
- Final source/diff/interface/test/documentation reviews have no open findings.
  Wording corrections explicitly restrict the 0.002 scaling distance bound
  to the scaled reference and identify the joint radius/blend/epsilon ablation.
  No unrelated bugs were found; the known upstream dark/chroma limitations
  belong to this candidate evaluation.
- Local documentation links pass. The archive preserves every raw JSON and
  all 588 PNGs; only 83 empty process logs are omitted and listed in
  `artifact-packaging.json`.
- **Clean full production build passed:** after confirming no active
  build/test/harness processes, alternate build paths or bundle lock,
  `.build/`, `.build-app/` and `dist/PicEdit.app` were removed. The preflight is
  recorded in `clean-build-preflight.json`; no source, user data or active lock
  was removed. `PICEDIT_BUILD_JOBS=6 ./scripts/build-app.sh` exits 0 and reports
  100.72 seconds. Five compiler jobs and one icon worker run in parallel; the
  script validates the plist and verifies the signed bundle before publishing.
- Compiler-diagnostic trailing whitespace in validation logs is normalized
  for `git diff --check`; messages and outcomes are preserved.

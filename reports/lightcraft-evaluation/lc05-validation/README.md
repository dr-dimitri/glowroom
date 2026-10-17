# LC-05 validation

Task branch: `codex/lc05-color-evaluation`, based on current remote `main`
`29d102b8044ce35d24d4de17910390d50daa1038`. No production renderer, settings,
preview scheduler, export path or UI implementation changes are included.

## Commands and evidence

```sh
python3 tools/lightcraft-evaluation/lc05-reference-oracle/generate.py /Users/wolfgangbauer/dev/workspace/lightcraft
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
./scripts/test.sh --jobs 3 --filter 'AlgorithmEvaluation|LightcraftColor|EditRendererTests|EditRenderSessionTests|AdjustedPreviewPipelineTests|JPEGExporterTests|AutoToneRendererTests'
PICEDIT_BUILD_JOBS=3 ./scripts/build-developer-tool.sh editing
python3 tools/lightcraft-evaluation/run.py reports/lightcraft-evaluation/lc05-2026-10-17 --binary .build-app/developer-tools/editing/out/Products/Release/PicEdit --candidate LC-05
```

- `oracle.log`: independent original-Rust regeneration verifies 24 cases ×
  20 input pixels against the committed vectors and source hashes.
- `python-tests.log`: all 53 evaluation-runner tests pass, including 22 LC-05
  cases for separate control decisions, input-relative metrics, matching,
  immutable numerical contracts and phase-specific performance attribution.
- `targeted-tests.log`: all 88 tests in 10 suites pass, including reference,
  metrics, profile/depth/alpha/cancellation, renderer, reusable session,
  adjusted-preview scheduling, AutoTone and JPEG-export coverage.
- `harness-build.log`: final release measurement-binary build.
- `evaluation.log`: serial acceptance/timing run progress; full commands,
  hardware, source/binary/manifest/calibration hashes and raw measurements
  reside in the adjacent LC-05 evidence directory.
- `lc01-smoke-summary.json`: existing generic quality route still produces
  126 records with no control failures; it correctly requires the specialized
  LC-05 route for acceptance. The temporary duplicate PNG set is not committed.

Native tests and developer-tool builds used separate build directories and
bounded compiler jobs. All builds/tests finish before measurements begin;
measurement processes run serially to avoid competing CPU/GPU/memory load.

## Diagnosed initial failures

The initial test build failed on an overly complex SIMD expression in the new
reference test; explicit typed intermediate components fixed Swift's type
checking. The initial harness build failed on a missing `try` around the
throwing difference-image helper. The next test run found the two split
assertions comparing `Optional<Double>` with an inferred integer product in
the new gradation test; unwrapping and explicitly comparing two `Double`
values fixes the test expression. The measured count was exactly 2520 in both
splits. No algorithm, manifest tolerance or acceptance outcome was changed.

These attempts remain in `initial-test-build-failure.log`,
`initial-harness-build-failure.log` and `initial-test-assertion-failure.log`.

## Review

Independent cross-reviews cover the original-source reference and Rust oracle,
fixtures/metrics, Swift/Python schema, calibration, separate decisions,
performance attribution and registry routing. The stage-diagnostic scope was
clarified to include AutoTone reanalysis of color-modified input as well as
intermediate materialization. This does not affect the primary decision.
Final result/documentation review and clean production-build evidence follow.

## Final result

- All 88 native tests and 53 Python tests pass; original-Rust oracle and the
  generic LC-01 route pass. The full LC-05 run completes successfully with
  separate `no-go` decisions for vibrance and saturation.
- Independent audits recompute the 216 matching/critical/contract rows and
  both decisions without contradictions. All 182 frozen source hashes plus
  manifest/calibration hashes match the final code. The runner verifies its
  binary hash throughout the run, including after the final scale step; the
  subsequent required clean build removes that measurement binary.
- All 80 timing processes provide 80 cold, 80 warmup and 400 warm samples.
  All effects match; the 24 scale records remain a diagnostic, not a
  production preview/export approval. Numerical claims and scope in the
  final documentation were reviewed against the raw data.
- No unrelated bugs were found. The task's compile/assertion issues and the
  AutoTone scope clarification are fixed; final source/diff/interface/tests/
  documentation review has no open findings.
- `clean-build-preflight.json` records absent alternate build paths, no
  active build/test/harness process or bundle lock, and verified generated
  directories before removing `.build/`, `.build-app/` and `dist/PicEdit.app`.
  No source, user data or active build lock was removed.
- **Clean full build passed:** `PICEDIT_BUILD_JOBS=6 ./scripts/build-app.sh`,
  exit 0; compiler reported 102.20 seconds. Five compiler jobs and one icon
  worker ran in parallel. The script validates the plist, signs the app and
  verifies its signature before publishing `dist/PicEdit.app`.
- Compiler-diagnostic trailing whitespace in validation logs is normalized
  for `git diff --check`; messages and outcomes are preserved. The result
  archive omits only 83 empty process logs, listed in `artifact-packaging.json`.

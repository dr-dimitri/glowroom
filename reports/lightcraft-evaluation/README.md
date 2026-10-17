# Lightcraft evaluation evidence

- `prechange/`: release measurements of unmodified `bf1900970089b26de9b76c37d83a5a168bf91de3`, captured before implementation. Five independent processes, each with five warm samples. Hardware serial/UUID identifiers omitted.
- `run-2026-10-17/`: complete synthetic evaluation, exact manifests and SHA256 provenance, 126 quality records, 54 passing controls, paired/difference PNGs, labeled/blind HTML, 20 timing processes and a full-resolution scaling comparison. All four future Lightcraft references remain **blocked**, not evaluated or approved.
- `validation/`: clean release build, full Swift suite and final focused Swift suite logs. Compiler-diagnostic trailing whitespace normalized. The full run includes the existing unrelated failure [#47](https://github.com/dr-dimitri/picedit/issues/47); the focused run passes 58 tests, including its isolated reproduction. The 302 Core tests pass.

Reproduce in a **new** directory:

```sh
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc01-reproduction
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-lc01-tests scripts/test.sh --jobs 4 --filter 'AlgorithmEvaluation|EditRendererTests|AutoToneRendererTests|JPEGExporterTests|expirationDuringFinalCurrentTokenLookupCannotPublishAfterTimerWasCancelled'
```

Do not run timing measurements concurrently with builds or other heavy work. The recipe regenerates identical deterministic inputs; timing values depend on hardware and system state. PNGs are display diagnostics; Float32 source hashes and quantitative values are authoritative. No personal or downloaded photo is included. These self-authored fixtures do not establish real-photo quality or a production performance gain. See [the complete method and decision report](../../docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md).

## LC-04: independent clarity and texture

- [`lc04-2026-10-17/`](lc04-2026-10-17/summary.json): original V1 protocol and complete evidence. Clarity has a matched color-compatibility veto; texture remains blocked. Primary edge fixtures lacked adequate independent matching support. Snapshots of the three subsequently changed Swift sources reproduce this archived version.
- [`lc04-matched-2026-10-17/`](lc04-matched-2026-10-17/summary.json): separately frozen V2 protocol with an independent gray detail probe in the upper half of the two primary scenes. Lower halo pixels, algorithms, thresholds and all other scenes stay unchanged. Both candidates receive independent **No-Go** decisions from matched overshoot violations; texture's moderate halo improvement is retained as a positive numerical finding.
- [`lc04-validation/`](lc04-validation/): native/Python tests, original-Rust oracle verification, harness and clean production-build logs, plus the diagnosed initial failed/interrupted attempts.

Each complete LC-04 run contains 140 quality comparisons, 105 near-zero diagnostics, 96 stage-order diagnostics, 80 separate timing processes, scaling results, frozen manifests/mappings, source/binary hashes and labeled/blind views. See the [method, results and limits](../../docs/LIGHTCRAFT-DETAIL-EVALUATION.md). Reproduce in a new directory with `./scripts/evaluate-lightcraft.sh /tmp/picedit-lc04-reproduction --candidate LC-04`.

## LC-05: independent vibrance and saturation

- [`lc05-2026-10-17/`](lc05-2026-10-17/summary.json): frozen color protocol, separate **No-Go** decisions despite improved matched moderate hue/lightness targets. Critical clipping/gradation guards and independent numerical gray contracts fail; the unbounded output-policy ablation is diagnosed separately.
- [`lc05-validation/`](lc05-validation/README.md): 88 focused native tests, 53 Python tests, 24 × 20 original-Rust oracle cases, generic LC-01 routing smoke check, build logs and diagnosed initial failed attempts.

The LC-05 run preserves 216 quality comparisons, 108 near-zero diagnostics,
18 independent full-desaturation cases, 64 stage diagnostics, 80 separate
timing processes, scale results and all frozen provenance plus paired/blind
views. Of 216 quality cases, 142 match the required effect strength. Synthetic
color distributions and the numerical gray tolerance do not establish real-photo
preference or a visible gray tint. See [method, findings and limits](../../docs/LIGHTCRAFT-COLOR-EVALUATION.md).
Reproduce in a new directory with `./scripts/evaluate-lightcraft.sh /tmp/picedit-lc05-reproduction --candidate LC-05`.

## LC-06: independent luminance, chroma and native scaling

- [`lc06-2026-10-18/`](lc06-2026-10-18/summary.json): three separate **No-Go**
  decisions. Luma misses detail/edge targets; chroma regresses on ordinary color
  lines as well as negative-Y source cases. Native scaling improves distance
  to downsampled full output, but seven cases violate the noise-reduction guard.
- [`lc06-validation/`](lc06-validation/README.md): 90 native tests, 78 Python
  tests, 40 original-Rust oracle cases, generic routing smoke check, analytical
  area-weight variance, harness and clean production-build evidence.

The archive preserves 48 quality cases (42 matched, including all primary
cases), 32 zero/near-zero and 32 stage diagnostics, 54 scaling records, 588
diagnostic/blind PNGs, and 80 timing processes. No timing effect pair matches;
those latency/RSS values are cost observations, not equal-effect performance
claims. Original source, binary, manifest and calibration hashes are frozen.
Licensed real photos, upstream original captures and blinded acceptance remain
missing; see [results and limits](../../docs/LIGHTCRAFT-DENOISE-EVALUATION.md).
Reproduce in a new directory with
`./scripts/evaluate-lightcraft.sh /tmp/picedit-lc06-reproduction --candidate LC-06`.

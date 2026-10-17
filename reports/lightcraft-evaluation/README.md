# LC-01 evidence

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

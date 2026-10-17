# LC-04 validation

- `targeted-tests.log`: 112 native tests in 12 suites pass, covering the isolated reference, shared LC-03 filters and existing renderer/session/preview/export/AutoTone contracts.
- `v2-targeted-tests.log`: 41 tests in five suites pass after the primary-probe correction, including its two new independent-region tests.
- `python-tests.log`: all 31 runner tests pass with the final manifest.
- `oracle.log`: 12 frozen original-Rust cases independently regenerated and verified.
- `lc01-smoke-summary.json`: all 126 generic control records pass; specialized LC-03/LC-04 references correctly stay blocked in the generic mode.
- `harness-final-build.log`, `v2-harness-build.log`: successful release harness builds used by the separate archived measurement runs.
- `evaluation.log`, `v2-evaluation.log`: both complete runs, without concurrent heavy work.
- `clean-build.log`: successful full `PICEDIT_BUILD_JOBS=6 ./scripts/build-app.sh`, including bundle/signature checks, after inactive `.build`, `.build-app` and `dist/PicEdit.app` were removed. No custom build paths or active build lock were present.

Initial failures are retained: dependency access failed inside the sandbox; two Swift Testing macro expressions initially failed compilation and were corrected; a subsequent sandbox test process stalled during Metal initialization and was diagnosed/terminated. The final native tests and builds used normal Core Image/Metal and dependency access and passed.

Final independent reviews covered native/reference code, oracle provenance, measurements, Python gating, interfaces, documentation and raw-result consistency. Documentation precision findings were resolved. No unrelated new bug was found. The production renderer and settings remain unchanged; no-go results and incomplete evidence are documented separately in the [complete report](../../../docs/LIGHTCRAFT-DETAIL-EVALUATION.md).

Compiler-diagnostic trailing whitespace is normalized in validation logs only. `artifact-packaging.json` lists zero-byte per-process logs omitted from the two run archives; measurements, source snapshots, exact commands and all PNG/HTML evidence are preserved.

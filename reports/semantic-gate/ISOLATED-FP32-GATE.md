# Isolated corrected SigLIP2 gate

16October2026; M2Pro12CPU/16GiB, macOS27.0.1, Swift6.4 Release, two build jobs. No concurrent project builds/tests/model inference during the measured processes. No PicEdit repository/Git changes. Ground truth SHA remains `c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025`; all prior failing conversions and measurements remain preserved.

## Result

The corrected Float32 image tower with unchanged FP16 text tower meets every fixed gate **in the measured text-first/per-model-autoreleasepool lifecycle**, in both `.all` and `.cpuOnly`. The naive tokenizer-first `.all` lifecycle fails the unchanged memory gate and must not be shipped unchanged. No threshold, fixture or query was adjusted.

| Measured fresh-process lifecycle | Extra peak RSS bytes | Warm full query p50/p95 | Outcome |
|---|---:|---:|---|
|Tokenizer-first, `.all`, first staged path|2,070,593,536|5.958/6.354ms|**RSS FAIL**|
|Tokenizer-first, CPU|1,409,777,664|8.775/9.261ms|PASS|
|Image-first pool, `.all`, same now-warmer path|1,210,105,856|5.919/6.257ms|PASS; cache-confounded comparison|
|**Text-first per-model pool, `.all`, new UUID path**|**1,579,778,048**|**5.879/6.187ms**|PASS with narrow RSS margin|
|**Text-first per-model pool, CPU, separate fresh process**|**1,141,882,880**|**8.833/9.309ms**|PASS|

Fixed RSS maximum:1,610,612,736bytes(1.5GiB). The selected `.all` run has only30,834,688bytes(29.4MiB) margin. This is a measured pass on this machine, not an integrated PicEdit RAM guarantee or a broad hardware/first-installation claim. The original2.07GB failure remains a real result; it is not replaced by a warmed rerun.

For the selected runs, external `/usr/bin/time -lp` independently confirms complete-process maximum RSS1,586,921,472bytes (`.all`) and1,149,026,304bytes(CPU). Each process baseline before model/tokenizer loading was7,143,424bytes. The external peak equals the internal recorded peak, so serialization/reporting did not hide an additional peak.

## Frozen functional gates

Both selected modes revalidate all8Unicode/tokenizer golden cases and all50query token sequences with the pinned native Swift tokenizer. The30image encodings and50text encodings are compared to the unchanged PyTorch reference with normalized cosine-distance tolerance0.001.

- Maximum image distance: `.all`0.000001370907; CPU0.000001251698.
- Maximum text distance: `.all`0.00001466274; CPU0.00008374453.
- Positive Top5 retrieval:20/20German and20/20English; zero language gap.
- The five unchanged negative DE/ENpairs have full raw rankings/scores preserved. No universal probability/rejection threshold is inferred.

These distances use the original native harness Float32 dot reduction; the earlier narrow precision diagnostic used Double accumulation. The tiny difference in reported image error is arithmetic, not changed model/fixtures/tolerance.

## Active installed files and notices

The selected active runtime is recorded in `text-first-runtime-path.txt` and the summary. It contains **983,299,012bytes** in33files, including both compiled models, the JSON tokenizer and required configs, executable, resource bundles, model card, model/conversion attribution, pinned Swift dependency licenses/notices and its manifest. It contains no original checkpoint, duplicate `.mlpackage`, Python runtime or duplicate SentencePiece model.

`runtime-manifest.json` in that directory records per-file exact sizes/SHA-256. Its own bytes are counted by the runtime gate but excluded from its recursive self-hash list. A fresh UUID APFSclone was created and its complete payload signatures were asserted equal to the prepared template before either selected process. Packages and compiled copies are alternative representations; retaining both after installation would exceed this model budget and is not the proposed runtime.

## Loading and model-only throughput

The selected lifecycle loads the larger text model first in its own autoreleasepool, drains the pool, loads the image model in a second pool, drains it, then loads the tokenizer. Both models stay strongly retained for all subsequent encoding/search. This changes lifetime of temporary loading allocations, not model graphs or outputs.

| Selected measurement | `.all` |CPU|
|---|---:|---:|
|Both model constructors/load|4.510s|0.511s|
|Tokenizer load|1.515s|1.428s|
|30tensor-to-image encodings, first included|18.35images/s|17.94images/s|
|Last29image encodings|19.45images/s|18.20images/s|
|Linear10ksearch+top100sort p50/p95|1.269/1.389ms|1.377/1.492ms|
|Saved-query-vector reuse+search p50/p95|1.186/1.365ms|1.243/1.363ms|

The image rates exclude original-file decode, color conversion and preprocessing: the same frozen `[1,3,256,256]` input tensors were used. The cached-query column reuses precomputed query vectors and times the same linear search/top100sort; it is not an implemented product LRU. Warm full-query measurements perform actual native tokenization, text inference and the10ksearch100times. No accelerator selection is asserted merely because `.all` permits Core ML to choose one.

## Cache and scope limits

Every measured invocation was a new process with empty app model/query state. The selected `.all` invocation used a new absolute UUIDruntime path. OS filesystem/Core ML caches had already been used, remained uncontrolled and were never purged. Checksumming/cloning also touches files before measurement. Therefore these are fresh-process/staged-path results, not a guaranteed virgin OS/Core ML installation or cold-storage benchmark. The loading/RSS stages are retained in every raw JSON, including failures.

Only one selected invocation per execution mode was measured. No confidence intervals, thermal sweep, Intel/macOS14, integrated PicEdit memory, real-camera RAW throughput or photographic retrieval quality was measured. The strict initial memory failure and narrow selected `.all` margin require care during product integration and its resource review.

## Reproduction and artifacts

- Final harness: `native-fp32-isolated/Sources/SemanticFP32Gate/main.swift` with `Package.swift` and unchanged `Package.resolved`.
- V1source: `native-fp32-isolated/main-v1-before-text-first.swift.txt`; V1binary/runtime remain in `runtime-fp32-isolated`.
- `stage-text-first-runtime.py` stages the built executable/resources, creates a new APFS UUIDclone and verifies equal payload hashes. It preserves all earlier UUIDdirectories.
- `run-text-first-gate.py all <unique-tag>` / `cpu <unique-tag>` run separate native processes under external `time -lp`; output creation refuses existing logs/results.
- `isolated-fp32-gate-summary.json` contains all five lifecycle rows and every unchanged acceptance threshold. Raw vectors, timing samples, RSS stages and retrieval rankings remain in `native-fp32-isolated-*-results.json`.

Release build command, outside the restrictive tool sandbox because its first attempt blocked dsymutil after successful compilation/linking:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/picedit-semantic-gate/native-fp32-isolated-build/ModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/picedit-semantic-gate/native-fp32-isolated-build/ModuleCache xcrun swift build --disable-sandbox --force-resolved-versions --skip-update --jobs 2 -c release --package-path /private/tmp/picedit-semantic-gate/native-fp32-isolated --scratch-path /private/tmp/picedit-semantic-gate/native-fp32-isolated-build
```

Dependency checkouts were already present and remained at their pinned revisions; no network/model downloads or venv modifications occurred. Torch/Accelerate thread limits were set to2where supported. Native inference was serial; public Core ML API does not expose a guaranteed internal thread-count cap.

All builds/inference ended before release of the exclusive measurement window. No product capability was enabled.

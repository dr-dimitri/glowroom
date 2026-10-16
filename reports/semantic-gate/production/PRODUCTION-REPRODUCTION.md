# Production semantic import reproduction

**Final integrated performance gate: PASS.** The final uninfluenced Release run verified all 10,000 current sources before timing and passed the unchanged latency and additional-RSS limits. Historical raw PASS flags remain qualified separately; they did not prove full current-source admission.

16 October 2026, same M2 Pro / 16 GiB and pinned offline source as the selection gate. No network, weight download, personal photographs or ground-truth changes. Developer conversion ran one tower at a time with two CPU threads to bound checkpoint memory. Native predictions were serial.

## Strict export correction and proofs

The first preflight rejected the installed metadata spelling `coremltools 8.3.0` versus the equivalent PEP 440 pin `8.3`; the script now uses semantic version comparison. No package version was changed. The first actual image export then correctly failed its raw graph SHA. Exact protobuf comparison found no field/value difference at all: only default map wire ordering changed between processes. Root independently verified this equality.

| Graph | Original raw SHA256 | Approved deterministic SHA256 | Bytes |
|---|---|---|---:|
| Image | `131150818a0ab0d93787b5e72c75ebcb106d14a40f9a276442ea6de460d74a9c` | `2e832f61dfb25bf234f4efffdfd6910cf620032ed7bea6365228547acee0c25d` | 123,281 |
| Text | `8712ed5ada6dde3637ce7d8ea15adce7f08a73beab22ce387ab6679f72b5a58a` | `ec95a2cdb969b0916e4c50128fa6612a4285359b95d08b3d13b0937232285ce5` | 127,557 |

The original and canonical messages are equal; deterministic serialization produces the same bytes from both image files. This is an explicit representation correction to the initial, unreleased import manifest, not acceptance of arbitrary hashes. The fixed package UUID templates and every weight/source/token/fixture/quality pin remain unchanged. The conversion notice was separately reformatted for readable attribution and only its own size/hash changed. Failed outputs/logs and the old manifest are preserved.

Both fresh canonical tower exports passed every strict graph, weight and package-template hash. `bundle-model.py` then created the approved portable package: 15 files, 975,162,333 bytes. It copies only the whitelist and no original checkpoint or Python runtime. Installed compiler outputs are materialized as independent private files; the native framework's hardlinked compiler-cache weights are not retained as aliases.

## Functional production component tests

The original public offline Config Codable path matched all 58 frozen token sequences exactly. The initially chosen raw research-source config files had three hardlinks from earlier research staging and were intentionally rejected by the new single-link contract; independently copied approved-package files passed. This was an input-layout rejection, not a token mismatch.

The real installer, shared original preview preparation and CPU-only native provider then passed all 30 images and 50 queries against unchanged PyTorch vectors. Maximum normalized cosine distances were 0.0000001009193 for images and 0.0000834110 for text. Positive Top-5 hits were 20/20 in German and 20/20 in English. Thresholds remained 0.001 parity, at least 80% per language and at most ten percentage points language gap. Negative queries remained included among the 50 text vectors; historical full negative rankings are retained separately. Active generation including receipt was 975,212,706 bytes, without duplicate portable packages.

This was a direct production component test, not a claim that the Library UI or full indexing service was benchmarked. Installer/global-lease and lifecycle orchestration have separate fake tests; the subsequent installed-runtime Release baseline is recorded below.

## Memory result is not a pass

The full debug Swift Testing process, including source verification, actual import/compile, tokenizer construction, native provider and fixture preparation, had external `time -lp` maximum RSS **3,377,577,984 bytes**. The native component test took 34.086 seconds; complete process wall time was 36.35 seconds. These are debug verification observations, not application latency claims. No additional-RSS baseline or phase attribution was captured here. This result must not be described as meeting the unchanged 1.5 GiB extra-RSS target or replace the isolated historical model gate.

Per-tower compiler constructors already have separate autoreleasepools. The original observation is retained without phase attribution. After the Release baseline below, per-chunk I/O pools and public offline Config dictionary construction were applied together. Their subsequent combined measurements are recorded below. The original 3.378 GB observation remains intact; the two changes were not evaluated separately.

`production-reproduction-summary.json` records tool versions, paths, byte counts and exact evidence logs. No old macOS/Intel or private-photo quality claim is added.

## Installed-runtime Release baseline before memory patch

A separate fresh-process Release run used the real provider and indexing/search service with the already installed generation. The runtime was not reimported or compiled. Its raw JSON recorded true flags against the unchanged 1.5 GiB additional-RSS and 500 ms warm-query p95 limits; retrospective Date-precision analysis means this is not a fully covered current-source acceptance: additional peak was **1,473,478,656 bytes**, total process high-water **1,551,564,800 bytes**, versus resident baseline **78,086,144 bytes**. First integrity verification, model load and one encode took **14,339.391 ms**. Warm distinct-query p50/p95 were **446.638/464.378 ms**; repeated query-cache p50/p95 were **439.271/442.007 ms**.

The 10,000 distinct synthetic files repeat 30 frozen image contents/reference vectors. Setup includes preparation and SQLite seeding, not 10,000 measured image encoder calls. The measured queries include all-candidate source stamp validation, SQLite page reads, ranking, actor coordination and a native encode on cache misses. They did not yet verify that all 10,000 unchanged source fingerprints survived exact Date comparison for ranking admission. OS file caches were already warm after setup; these are not cold filesystem, first-install, RAW, private-photo, or graphical-app measurements. The process high-water minus pre-load resident RSS is conservative process accounting, not a model-allocation claim. The full raw result and all recorded limitations are retained losslessly in `release-before-memory-patch-results.json.gz`.

The baseline used CPU-only CoreML on macOS 27.0.1 (26A434), Mac14,10 (M2 Pro), 16 GiB RAM. Root owns full SDK/fallback/build matrix reporting; no Intel or real older-OS execution is claimed here. Import/compilation remains a separate path whose earlier 3.378 GB peak is not excused by this installed-runtime result. The same Release benchmark was repeated after the memory patch, with the separate outcome below.

## Combined memory patch: measured after results

One autoreleasepool per bounded I/O chunk and the public offline Config dictionary initializer were applied together. The tokenizer algorithm, all 58 golden cases, 30 images, 50 queries, source/weight/graph pins and acceptance limits stayed unchanged. The new debug token test passed all 58 exact sequences in **6.987 s** (whole process 9.91 s, maximum RSS 359,841,792 bytes). The new real debug import/provider test passed **30/50**, with the same maximum image/text cosine distances **0.0000001009193/0.0000834110** and German/English Top-5 hits **20/20 each**. Its test time was **22.253 s**, whole process 24.44 s, maximum RSS **1,173,520,384 bytes**. Runtime bytes remained **975,212,706**.

| Observed path | Before combined patch | After combined patch | Interpretation |
|---|---:|---:|---|
| Complete debug import/compile/provider process peak | 3,377,577,984 B | 1,173,520,384 B | Different runs; original high-memory failure remains evidence |
| Installed-runtime Release additional process peak | 1,473,478,656 B | 462,651,392 B | Both pass the unchanged 1.5 GiB additional-RSS limit |
| Installed-runtime Release total process high-water | 1,551,564,800 B | 538,902,528 B | Whole process, not isolated model allocations |
| First Release integrity/hash, load and encode | 14,339.391 ms | 3,595.540 ms | Includes verification and one native encode |
| Release warm distinct-query p50/p95 | 446.638 / 464.378 ms | 457.275 / **510.314 ms** | Historical after-patch p95 **FAILS** the unchanged 500 ms limit; neither run proved full current-source admission |
| Release query-cache p50/p95 | 439.271 / 442.007 ms | 466.364 / **524.615 ms** | Cache hits still validate sources and rank all candidates |

The lower observed memory and first-load time belong to the combined implementation variant. Neither subchange's individual contribution is isolated. These are fresh processes on the same hardware, with serial runs and warmed OS/CoreML caches; filesystem cache contents, framework specialization caches and thermal state were not controlled. They do not establish virgin-install performance or an across-device guarantee. Debug complete-import measurements and Release already-installed measurements serve different purposes and must not be combined into one memory or latency claim.

The new native test retains ten bounded RSS snapshots in `native-after-memory-rss.json`:

| Checkpoint | Elapsed ms | Resident RSS B | Cumulative process high-water B |
|---|---:|---:|---:|
| before-inspect | 0.032 | 22,462,464 | 22,462,464 |
| after-inspect | 465.772 | 25,788,416 | 25,788,416 |
| install-verifying | 466.011 | 25,788,416 | 25,788,416 |
| install-copying | 931.865 | 27,951,104 | 27,951,104 |
| install-compiling | 1,462.900 | 27,983,872 | 27,983,872 |
| install-publishing | 3,023.477 | 36,569,088 | 39,354,368 |
| after-install | 3,023.987 | 36,601,856 | 39,354,368 |
| after-first-encode-and-load | 11,144.879 | 720,060,416 | 1,173,520,384 |
| after-30-images | 21,515.041 | 732,774,400 | 1,173,520,384 |
| after-30-images-50-queries | 22,195.458 | 906,248,192 | 1,173,520,384 |

The observed import/compile/publication phase completed with cumulative high-water **39,354,368 bytes**. By the first completed image encode/load the process high-water reached **1,173,520,384 bytes**, and stayed there through 30 images/50 queries. These boundaries locate the largest observed interval after installation and through lazy verification/model/tokenizer initialization/first prediction; they do not distinguish allocations inside that interval. Native compiler and OS/CoreML caches were already warm. No original-run phase snapshots exist, so attributing the old 3.378 GB peak to a specific phase would be unsupported.

**Historical open-gate observations are preserved.** The after-memory-patch Release latency FAIL and subsequent batch/SIMD FAIL remain intact. The later pre-fix PASS observations below still lack proof of complete current-source admission. The final corrected, fully covered PASS is recorded after them; latency, memory and relevance limits were not relaxed.

## Later Release measurements and delayed profiling

All three raw JSON bodies are archived losslessly; exact values remain in the summary and gzip archives. The table rounds display values to three decimals.

| Run (UUID prefix) | Warm distinct p50 / p95 ms | Query cache p50 / p95 ms | Additional peak RSS B | Raw flags / admissible interpretation |
|---|---:|---:|---:|---|
| Batch + deterministic SIMD (`965D0B12`) | 490.639 / **541.833** | 456.195 / 479.293 | 440,811,520 | Latency FAIL, memory flag true; complete current-source coverage unverified |
| Profiled diagnostic (`AC6D066F`) | 465.375 / 483.824 | 459.144 / **675.188** | 462,929,920 | Raw warm-latency and memory flags true; profiling perturbed the run and coverage was unverified; no uninfluenced acceptance |
| URL fastpath, before Date fix (`A66B9DDF`) | 338.079 / 364.538 | 320.928 / 353.555 | 453,820,416 | Raw warm-latency and memory flags true; complete current-source coverage unverified |

Each used the same installed 975,212,706-byte CPU-only runtime, 10,000 distinct synthetic files, 20 different warm queries and 20 exact query-cache repeats. Cache-miss native encoding still ran exactly once per query and cache repeats ran no native encode. These are observations of successive complete implementation variants; caches, thermals and individual optimization contributions were not isolated.

`semantic-query-tail-sample.txt.gz` preserves the profiler output byte for byte. Ten seconds were requested, but the header records process launch at **15:01:01.964 +0200** and sampling at **15:01:29.721 +0200**: a **27.757 s** delay. The graph contains 2,127 one-millisecond main-thread samples, approximately **2.127 s** of the tail. It does not cover ten seconds or the complete query run. Its source-stamping stacks supported diagnosis; it cannot apportion the entire workload or establish an unprofiled gate PASS.

## Source Date precision defect and coverage correction

The old SQLite representation converted `Date` to `timeIntervalSince1970`, then reconstructed `Date(timeIntervalSince1970:)`. Adding and subtracting that epoch offset can lose a native Date ULP at contemporary timestamps. The unchanged five-file synthetic probe is retained as `source-date-precision-probe.swift`, `.json` and `.log`:

| Synthetic row | Date equal after old roundtrip | Unix Double equal | Native reference delta ns |
|---|---|---|---:|
| 00014 | false | true | -119.20928955078125 |
| 00044 | true | true | 0 |
| 00074 | false | true | +119.20928955078125 |
| 00104 | false | true | +119.20928955078125 |
| 00134 | true | true | 0 |

The Unix Doubles compared equal even where reconstructed Dates differed. Exact source-fingerprint equality therefore excluded some unchanged files from ranking admission. The older runs still read 10,000 SQLite rows/catalog candidates and performed all-candidate native freshness checks; they **did not prove that all 10,000 current sources were admitted**. Their raw JSON, original flags, memory observations and FAILs remain unchanged, but no historical PASS supplies final fully covered acceptance.

The unreleased schema now explicitly stores `source_mtime_reference REAL` using `Date.timeIntervalSinceReferenceDate` and reconstructs `Date(timeIntervalSinceReferenceDate:)`. Strict schema validation rejects old developer index layouts for explicit preservation/quarantine/rebuild. The source fingerprint comparison and native freshness checks remain unchanged. Restart regression cases use the native reference Double's `nextUp` and `nextDown` values.

The final measured run required the real service to report **indexedCount == 10,000, missingCount == 0, staleCount == 0** before timing; its raw report retains `verifiedIndexedCandidateCount == 10000`. This corrected full-coverage run supplies the acceptance evidence below; the earlier raw results remain unchanged.

## Final uninfluenced Release run with complete current-source coverage

Run `5B4BE36F-671F-4ADA-A76F-05A7DE44F0BA`, recorded **2026-10-16T13:13:58Z**, passed both unchanged gates after exact Date persistence and full coverage verification. The real production service verified **10,000 indexed/current candidates out of 10,000**, with zero missing/stale required before timing. No profiler, build or other model workload competed with the measurement.

| Final observation | Exact value |
|---|---:|
| Warm distinct query p50 | 316.5296249790117 ms |
| Warm distinct query p95 | **338.519083277788 ms** (limit 500 ms) |
| Query-cache repeat p50 | 302.9752500005998 ms |
| Query-cache repeat p95 | 318.6125416541472 ms |
| Resident baseline before provider load | 82,509,824 B |
| Process high-water | 540,098,560 B |
| Additional process peak | **457,588,736 B** (limit 1,610,612,736 B) |
| First integrity/hash + load + encode | 4,083.6719166254625 ms |
| First complete service query | 360.700250021182 ms |
| Resident RSS after load | 534,429,696 B |

All 20 distinct warm queries performed one native encode each; all 20 exact repeats performed zero native encodes. Each complete query still includes all-candidate production native source stamps, SQLite reads, deterministic bounded SIMD ranking and final-hit freshness checks. The first service result now includes `synthetic-00014`, `00044`, `00074`, `00104`, `00134`, then all subsequent equal-content candidates in stable catalog order, with exactly equal scores (`0.0725145` for those entries). This corrects the pre-fix exclusion demonstrated by the Date probe.

The unchanged real native parity/quality evidence above remains applicable: 30 images/50 text queries, image/text cosine distance within 0.001 and 20/20 positive Top-5 hits in each language. This final integration run seeds 10,000 rows from the 30 frozen image vectors rather than encoding 10,000 images; it measures complete query service performance, not indexing throughput or 10,000 distinct image-content quality. OS caches are warm after setup and explicit full coverage verification. Additional peak is whole-process high-water minus resident baseline, not isolated model allocation. First load includes integrity verification and one encode. One Mac14,10/M2 Pro, 16 GiB, macOS 27.0.1 CPU-only run establishes this measured gate; it does not establish cold filesystem, RAW/GUI latency, older OS/Intel or across-device performance.

`release-final-full-coverage-results.json.gz` retains the complete raw result including all hit IDs/scores and limits, and `release-final-full-coverage-benchmark.log` records the successful one-test run (24.972 s). All historical FAILs, the profiled diagnostic PASS and incomplete-coverage pre-fix PASSs remain archived. **Final full-coverage integrated performance acceptance: PASS.** Root separately owns final clean bundle build and release/merge reporting.

## Evidence and reproduction

`artifact-manifest.json` preserves all original 18 evidence entries and pins the additional raw logs, Date probe and lossless Release/profile archives. Every gzip entry includes the uncompressed byte count and SHA256 as well as the compressed SHA256. `production-reproduction-summary.json` records versions, strict pins and measurements. The portable package and active runtime remain only under `/private/tmp/picedit-semantic-product-reproduction`; no weights, vocabulary or checkpoint are committed. Frozen fixtures and vectors are under `Fixtures/Semantic`.

The two fresh exports used `scripts/semantic/convert-model.py`, one tower per process, `--source` pointing to the exact verified offline source directory, and `--tower image` / `--tower text`, followed by `scripts/semantic/bundle-model.py` with the two generated package paths and tokenizer source. Exact developer CLI options remain in each script's `--help` and the checked-in product documentation. Conversion tools are developer-only Python; PicEdit uses native CoreML and the Swift tokenizer offline.

The token command sets `PICEDIT_RUN_SEMANTIC_TOKENIZER_TESTS=1` and `PICEDIT_SEMANTIC_TOKENIZER_DIR` to the approved portable package's `tokenizer` directory, then runs `./scripts/test.sh --filter SemanticTokenizerTests`. The native command sets `PICEDIT_RUN_SEMANTIC_MODEL_TESTS=1`, `PICEDIT_SEMANTIC_PACKAGE_DIR` to the approved portable package and `PICEDIT_SEMANTIC_INSTALL_DIR` to a dedicated `/private/tmp` install root, then runs `./scripts/test.sh --filter SemanticNativeModelTests`. Predictions are serial, share the application AI resource lease, and must be scheduled without competing model/build workloads for performance observations.


For the integrated benchmark, compile once with opt-in unset, then run only the built Release test in an exclusive measurement window. The dedicated scratch path must already contain the resolved dependencies; the install directory must contain an approved existing runtime. These commands do not import, convert or download model weights:

```sh
PICEDIT_TEST_BUILD_PATH=/private/tmp/picedit-semantic-repro-release \
  ./scripts/test.sh --configuration release --jobs 2 \
  --filter SemanticIntegrationBenchmarkTests

PICEDIT_RUN_SEMANTIC_INTEGRATION_BENCHMARK=1 \
PICEDIT_SEMANTIC_INSTALL_DIR=/private/tmp/picedit-semantic-product-reproduction/installed-model \
PICEDIT_TEST_BUILD_PATH=/private/tmp/picedit-semantic-repro-release \
  ./scripts/test.sh --configuration release --jobs 2 --skip-build \
  --filter SemanticIntegrationBenchmarkTests
```

The first command is compilation plus an intentionally skipped opt-in test, not benchmark evidence. The second writes a fresh UUID directory under `/private/tmp/picedit-semantic-integration-benchmark`, including raw `results.json` before a gate failure. Do not run a profiler, build, other model or concurrent benchmark during the acceptance measurement. The diagnostic profiler sample retained here is explicitly excluded from acceptance.

# SigLIP2 Core ML CPU image parity correction

2026-10-16. Research only in `/private/tmp/picedit-semantic-gate`; no PicEdit repository or Git changes. Source revision remains `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`. Ground truth remains SHA-256 `c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025`. No fixture, query, tokenizer, reference vector, original conversion or original native result was modified. No network/download, private photograph or venv package change.

## Finding and smallest configuration correction

The original image FP16 ML Program is not parity-safe with Core ML `.cpuOnly` on this macOS27/M2 Pro runtime. The same image graph/inputs passed with `.all`; an all-Float32 image graph passes both execution choices. This isolates the failure to reduced-precision native execution of the image graph, rather than source pairing, input tensors, tokenization or reference preprocessing. It does not identify or prove a particular internal Apple kernel defect.

Keeping all26 LayerNorms in Float32 does not fix the failure. Keeping those plus all13Softmaxes does not fix it. Keeping just the initial patch convolution in Float32 reduces the maximum error substantially, but still fails. Therefore a claim that LayerNorm alone was the cause would be unsupported.

The smallest **configuration/code** correction with complete measured functional equivalence is `compute_precision=ct.precision.FLOAT32` for the image tower only; the original FP16 text package is retained unchanged. This avoids maintaining a fragile list of selected operations. No tolerance was relaxed. A smaller mixed-precision package might be possible, but has not been established and is unnecessary to meet the measured model-file size target.

| Image variant | CPU max normalized cosine distance | Fixed <=0.001 gate | Image package bytes |
|---|---:|---|---:|
| Original FP16 (root prior probe) | 0.1011873 | FAIL |188,075,227|
|26LayerNorms Float32; rest FP16|0.1014748532|FAIL|188,168,798|
|26LayerNorms+13Softmaxes Float32; rest FP16|0.1011803505|FAIL|188,176,289|
|Patch convolution Float32; rest FP16|0.02380217965|FAIL|192,795,306|
|Entire image tower Float32|0.0000004620372|PASS|375,984,186|

The complete Float32 image tower also passes `.all`: maximum distance0.0000004084406. All30 image fixtures pass separately in both execution modes. Retrieval uses the previously saved, already validated native text vectors for the matching mode:20/20positive Top5 queries in German and20/20in English in each case. Raw rankings/scores for all50queries, including the unchanged five negative pairs, are preserved in the new result JSON. These simple drawings do not measure photographic search quality or establish an out-of-domain probability threshold.

## Actual artifact accounting

`precision-diagnostics-summary.json` includes sorted per-file sizes and SHA-256 values, separate for alternative package and compiled representations:

- Float32 image `.mlpackage`, original FP16 text `.mlpackage`, JSON tokenizer, tokenizer config, special tokens, model config, preprocessing config and model README: **975,147,490bytes**.
- Float32 image `.mlmodelc`, original FP16 text `.mlmodelc`, same tokenizer/config/README files: **975,198,182bytes**.

Both measured alternatives are below1GiB(1,073,741,824bytes); license/NOTICE distribution staging remains to be completed separately. A deployed installation retaining both complete package and compiled copies must count both; these alternative totals are not permission to omit duplicate deployed data. Original1.5GBFP32 source checkpoint, reference environment and rejected conversion variants are developer research artifacts, not proposed runtime files.

## Reproducible scripts and preserved data

- `convert-precision.py`: offline, fixed image tower and shape, original eager reference architecture,26LayerNorm/Softmax/attention selectors or complete Float32. Sets Torch intra-op2, inter-op1 and common BLAS/Accelerate thread limits2. Refuses to overwrite an existing variant.
- `convert-precision-v2.py`: same conversion with a single-convolution selector for the rejected narrower diagnostic.
- `precision-probe.swift`: standalone native functional harness, no tokenizer/source changes. Asserts frozen ground truth, loads the same30Float32input tensors, normalizes768outputs and compares against the same saved Torch reference. Native calls are serial; Core ML `.cpuOnly`/`.all` selection is explicit. Public Core ML API does not expose a guaranteed internal worker-thread cap; no private runtime setting is used.
- `summarize-precision.py`: read-only result summary and file-manifest reproduction.
- `image-fp32.mlpackage`, `image-fp32.mlmodelc`: passing corrected image artifacts.
- `native-fp32-cpu-image-parity.json`, `native-fp32-all-image-parity.json`: passing complete raw vectors/rankings.
- `native-ln32-cpu-image-parity.json`, `native-lnsm32-cpu-image-parity.json`, `native-conv32-cpu-image-parity.json`: rejected variants retained unchanged.

Initial export command (requires absent target so an earlier measured artifact is never overwritten):

```sh
/private/tmp/picedit-semantic-convert-venv/bin/python /private/tmp/picedit-semantic-gate/convert-precision.py fp32
```

Recheck the existing passing artifact with a new output suffix, after coordination of native model/GPU work:

```sh
VECLIB_MAXIMUM_THREADS=2 OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 /private/tmp/picedit-semantic-gate/precision-probe fp32 cpu repeat1
VECLIB_MAXIMUM_THREADS=2 OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 /private/tmp/picedit-semantic-gate/precision-probe fp32 all repeat1
```

The Swift source compiles with `xcrun swiftc -O precision-probe.swift -o precision-probe`. Native framework compilation/prediction required execution outside the restrictive tool sandbox. The scripts do not request network services.

## Open gate

These were functional precision probes while independent app builds could run. No timings, RSS or speedup are claimed. A separate isolated full gate must still measure first and warm loads, additional peak RSS with both actual towers, index throughput and complete warm query/search p95 on10,000vectors. The previous FP16 first `.all` peak exceeded the1.5GiB target; the corrected candidate must be measured anew. No product capability has been enabled. Older macOS/Intel and real-camera photographs remain untested.

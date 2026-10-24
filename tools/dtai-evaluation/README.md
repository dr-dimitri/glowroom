# DTAI research adapters: #182, #183, #187

These independent Python tools are local research infrastructure. They do not
install/download weights, import darktable-ai Python code, alter Glowroom's
renderer, decode original photos, or grant product availability. The current
source audit returns **No-Go** for all three product integrations because the
required model, native and photographic evidence is absent.

## Reproduce the preflight

Python 3.11+ suffices for the source audit and geometry/gate tests:

```sh
python3 tools/dtai-evaluation/run.py audit \
  --source /path/to/darktable-ai --output /private/tmp/dtai-audit.json
python3 -m unittest discover -s tools/dtai-evaluation -p 'test_*.py'
```

Audit exit **2** means an expected research No-Go, **1** is an invalid input or
source-pin failure. Exit **0** in an inference command means only that the
reference command completed. No command can grant product Go. Reports and
output directories must be new. Tests without NumPy explicitly skip tensor
checks; a full verification must report zero skips. The committed report was
produced using system Python; the full tensor tests used the bundled research
Python with NumPy 2.3.5/Pillow 12.3.0. Those tests are contract smoke tests and
are not canonical model parity measurements.

`source-pins.json` binds 14 source/metadata files, converter bytes, `uv.lock`,
and three vendor gitlinks to darktable-ai revision
`76513a1e379b4265007bae768825b9a581944ff8`. Audit rejects changed bytes or an
initialized vendor checkout with changed revision/worktree. Uninitialized
vendors are reported honestly. Checkpoint/ONNX files have no known SHA-256 and
are **not** considered pinned by their upstream filenames/Google Drive URLs.
The audit never executes checkpoint deserialization or an upstream converter.

For model experiments, provision a separate environment with the exact
`requirements.txt` versions. They match the audited upstream lock (NumPy
1.26.4, Pillow 12.1.1, ONNX 1.20.1, ONNX Runtime 1.24.2); installation is an explicit
research-environment step. Conversion remains external and must retain its own
tool versions. No missing native environment is replaced by a mock parity run.

With the pinned ONNX package available, run the separate real-protobuf check:

```sh
python3 tools/dtai-evaluation/verify-onnx-protobuf.py
```

On 24 October 2026 all four checks passed with ONNX 1.20.1 and Protobuf 7.34.0:
inline storage accepted; direct, nested-graph and sparse-tensor ExternalData
rejected. This checks actual protobuf traversal, without ONNX Runtime sessions,
model weights or inference. The standard unit suite also covers deterministic
path-replacement races with explicitly labelled stubs.

## Conversion receipt and reference denoising

Each ONNX file requires a JSON receipt with `source_revision`,
`vendor_revision`, `checkpoint_sha256`, `converter_sha256`, `model_sha256`,
`precision: "float32"`, `opset: 20`, and nonempty `tool_versions`. The converter
hash must match `source-pins.json`. All input/model/receipt/frame/click files are
read once into immutable byte snapshots, under a combined 1 GiB byte budget.
SHA-256, JSON/NPY decoders and ONNX Runtime consume those identical bytes;
reports retain those snapshot digests. JSON rejects duplicate keys at every nesting
level and nonfinite constants. A pathname replacement A → B → A cannot
change the executed model or decoded input under the digest of A. The subsequent
path recheck is only an additional stale-file guard. ONNX is parsed from the
snapshot and every protobuf submessage is inspected: ExternalData declarations
are refused before Runtime construction, including tensors inside nested graphs,
attributes, sparse tensors and functions. Inline weights are required; no
unhashed sidecar is resolved. Runtime receives model bytes, never a model path. An encoder and decoder need separate receipts with the same
checkpoint hash. Record origin URLs, code and weight licence evidence and
conversion command alongside the receipt; it is a reproducibility record,
not legal or product approval.

```sh
python3 tools/dtai-evaluation/run.py denoise --variant nafnet \
  --model /local/model.onnx --receipt /local/conversion.json \
  --input /local/straight-encoded-srgb.npy --color-space encoded-srgb \
  --output /private/tmp/nafnet-output.npy --report /private/tmp/nafnet-run.json
```

`raw-linear` accepts `linear-rec2020`, `raw-bayer` accepts
`packed-camera-rggb`. Input is FP32 `[1,C,H,W]`, finite and [0,1]. No file is
silently decoded, resized, clipped, or quantized on this route. NAFNet uses
768×768 tiles, RawNIND uses 512×512. Mirrored 64-pixel halos are discarded;
last cores retain every row/column, including odd/small/singleton dimensions.
Raw Bayer doubles the packed spatial dimensions to reconstruct sensor extent;
it is not super-resolution. Gain matching follows the input mean and refuses
nonpositive/degenerate or nonfinite input/output means. This is deliberately
stricter than the upstream sign-flipping mean match: physically invalid output
must not become apparently valid RAW by multiplying by a negative gain.
Bayer outputs remain camera RGB until an explicit
camera-to-XYZ D65 matrix is supplied to `camera_to_rec2020`; no matrix direction
is guessed. Raw outputs are not clipped or adjusted against clean reference GT.
The linear variant is not accepted as a reconstruction of sensor values from a
developed sRGB photograph.

The reference adapter uses ONNX CPU FP32 with one intra/inter-op thread and
one tile in flight. It estimates its tensor allocations before output creation
(default 512 MiB). NPY v1/v2 headers must declare FP32 rank-four data with an
exact payload length within that tensor budget before NumPy allocates the array.
The separate 1 GiB snapshot budget bounds retained serialized bytes. These
budgets do not cap ONNX parsing/native allocations or OS RSS. Mirroring creates only one tile,
not an image-sized padded copy. Sequential inference provides isolated reference
work and avoids competing GPU/native resource measurements. Independent source
hash reads use four bounded I/O workers. Cancellation is observed before a
native call and after its actual return; stale output is then discarded. This
synchronous research path does not implement or replace the app's shared
`AIResourceBudget` admission. No in-app concurrency claim is made.

`transfer` accepts only straight SDR linear/encoded sRGB and preserves float
precision. Negative/HDR values fail before transformation. `preserve_alpha`
returns the unchanged alpha bits separately from the RGB model. The runner
accepts RGB-only tensors; alpha must stay in its caller's basis and is never
sent through a denoiser. NAFNet's placement in Glowroom's extended-linear-sRGB
float pipeline still requires fair-effect, color, alpha and preview/export
qualification; accepting SDR experiments is not a full-working-space licence.

## SegNext proposals

`PromptFrame` versions original continuous edge coordinates -> EXIF orientation
-> oriented crop -> clockwise quarter rotation -> preview/1024 prompt frame.
Pixel centres are `i+0.5`. Every click carries source SHA-256 and frame ID;
outside-crop/source/preparation mismatches fail. Arbitrary angles and fractional
raster crops are intentionally unqualified. All eight EXIF orientations and
four quarter rotations have pixel-marker and inverse-coordinate tests.

```sh
python3 tools/dtai-evaluation/run.py segnext \
  --encoder /local/encoder.onnx --decoder /local/decoder.onnx \
  --encoder-receipt /local/encoder.json --decoder-receipt /local/decoder.json \
  --input /local/existing-decoded-sdr-basis.npy \
  --frame /local/frame.json --clicks /local/clicks.json \
  --output /private/tmp/segnext-proposals
```

The basis is FP32 `[1,3,originalHeight,originalWidth]`, encoded sRGB SDR, already
decoded by its owner. `frame.json` contains `source_sha256`, `width`, `height`,
`exif_orientation`, optional oriented `crop: [x,y,w,h]`, and `turns: 0..3`.
Each ordered click is `{ "point": [x,y], "label": 1, "source_sha256": "...",
"frame_id": "..." }`; label 0 is a negative click. Obtain the frame ID from
`PromptFrame(**frame).identity`. Freeze the ordered list before evaluation.

The preparation applies that same raster geometry, resizes float channels with
Pillow Lanczos and explicitly bounds interpolation overshoot to [0,1]. The
upstream encoder owns ImageNet normalization; it is not applied twice. This
float preparation differs from the reference's uint8 resize and needs its own
parity assessment. A 32 MiB LRU (configurable 0..64 MiB) caches encoder features
by source/preparation, tensor bytes and both model hashes. Each next click runs
only the decoder. Feedback is binary FP32 0/1 at 1024, never SAM logits or an
unqualified BiRefNet matte. An iteration retains the exact previous click prefix
and appends one click. Changing the source/preparation/model invalidates feedback.

Proposals use the pinned reference order: logit >0 -> uint8 Lanczos to prepared
crop extent -> >127 -> inverse rotation/crop/orientation. Returned masks are in
the original raster's extent and zero outside the crop. They are separate output
files, with no saved-mask/undo mutation; there is no product UI or automatic
acceptance. Binary selection does not prove hair/transparency alpha coverage.

`binary_iou` computes binary-mask IoU, with empty/empty = 1. The diagnostic
`segnext-gate --cases /local/ious.json --output /private/tmp/gate.json` requires
12 unique records (`id`, `start_iou`, one to ten `click_ious`, and
`native_reference_iou`). NoC@85 is zero if the start already passes; otherwise
the first successful correction click or 11 for nonarrival. Positive and
negative clicks count equally. It reports all cases, nonarrival count and the
bounded mean. The issue's quality thresholds are ≥10/12 by five clicks, mean
final improvement ≥.05, native/reference mask IoU ≥.99. A numeric pass is labelled
`quality-pass-unqualified`: an IoU JSON cannot prove licensed frozen photos,
independent GT, native execution, memory limits or blind review. The repository
contains no invented photographic cases or fabricated native results.

## Study decisions

- [SegNext #182](../../docs/DTAI-SEGNEXT-EVALUATION.md)
- [NAFNet #183](../../docs/DTAI-NAFNET-EVALUATION.md)
- [RawNIND #187](../../docs/DTAI-RAWNIND-FEASIBILITY.md)
- [Machine-readable source audit](../../docs/dtai-evaluation/source-audit.json)

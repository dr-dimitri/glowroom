# Offline comparison of local masking models

These standalone developer tools do not change PicEdit's model selection or app
dependencies. The measured results and limitations are in
[the evaluation report](../../reports/mask-models/2026-10-20/README.md).

The seven private JPEGs are available only in this local checkout at
`Fixtures/LocalTestImages/test_picture1.jpg` through `test_picture7.jpg`.
Missing images are an explicit prerequisite failure. Never commit originals,
derived images, model weights, or private manifests containing image hashes.
All inference is local. Download only public model/code/dependency files.

## Common inputs and diagnostics

Use an isolated Python environment with Pillow and NumPy. `prepare.py` applies
EXIF orientation, converts embedded ICC profiles to sRGB (otherwise assumes
sRGB), and writes fresh metadata-free RGB PNGs bounded to 2048 pixels. It hashes
originals before and after preparation. The private manifest is outside Git.

```sh
python prepare.py ../../Fixtures/LocalTestImages /private/tmp/mask-evaluation/inputs
```

Run from this directory, or adjust the script paths. Add each input's absolute
PNG path to a private copy of `prompts.json`; the SAM2 manifest also accepts
`iterations: 2`. The committed prompts contain manual test annotations, not
VLM-generated grounding. The final fox box includes its extended right arm;
the initial narrower-box run remains separate in the local evaluation record.

`visual_diagnostics.py ROOT --models JSON` accepts a mapping of labels to mask
globs relative to ROOT, with `{id}` as the image identifier. It checks image
dimensions and original hashes, writes mask statistics, and renders a -2 EV
background change in linear sRGB. This is a diagnostic compositor, not an
end-to-end PicEdit editing test. Coverage fractions are not accuracy scores.

## Measurements

Run model construction, compilation and inference sequentially on the shared
machine; concurrent heavy jobs distort latency and memory. Independent setup
downloads, code review and source preparation may overlap. Use fresh output
directories. Preserve failed and stopped runs with their actual status.

`birefnet.swift` loads the approved, already compiled 1920 Core ML model and
processes all seven proxies with resident weights, repeating image 1. Compile
with `swiftc -O`; invoke with `MODEL.mlmodelc INPUTS OUTPUT gpu|cpu`.
Validate its source package against `SubjectMattingApprovedPackage.json` first.

`sam2-download.py` downloads and verifies the pinned public Apple Core ML
conversion of Meta SAM 2.1 Tiny. `sam2.swift` has `compile` and `run` commands
documented in its header. The encoder runs once per photo, while prompt and mask
decoders repeat against its cached features. Output is thresholded segmentation,
not a transparency matte. Run native GPU measurements with an accessible Core ML
service; sandbox-limited runs must be labelled separately.

`ben2.py` uses ONNX Runtime in an isolated environment. Pin `onnxruntime==1.31.0`,
plus NumPy/Pillow/psutil, and download `BEN2_Base.onnx` from the revision and
SHA-256 embedded in the script. Specify `--provider cpu|coreml`, `--input-dir`,
`--output-dir`, and `--model`. Choose `--preprocessing pytorch` for the original
Lanczos/ImageNet pipeline, or `onnx-example` to reproduce the published ONNX
example. `--save-raw` retains native prediction arrays before min-max scaling.
The Core ML provider permits CPU fallback and
does not prove exclusive GPU execution. Its load time includes graph setup and
potential Core ML compilation. See the report for the upstream preprocessing
discrepancy and reference runs; do not mix their variants.

`ben2_reference.py` audits the pinned original safetensors checkpoint against
the native ONNX paths. It uses strict tensor loading and records the two
preprocessing variants explicitly. Its source/dependency pins are in the script.

The [additional candidate instructions](extra_README.md) describe pinned
BiRefNet GGUF/vision.cpp and EfficientSAM3 EV-M setups, including compatibility
accommodations and external timeouts.

Process RSS includes each harness/runtime and omits some GPU/driver allocations.
First-use measurements do not establish cold-cache performance: system caches
are not purged. Loading, inference, aspect restoration and PNG export have
different scopes across runtimes; compare labelled components, not unqualified
request fields. None of these photographs has a ground-truth alpha matte.

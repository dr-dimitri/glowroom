# Offline comparison of local masking models

These standalone developer tools do not change Glowroom's model selection or app
dependencies. Historical reports were removed with the `reports` directory.
The product limitations remain documented in [Automatic masks](../../docs/AUTOMATIC-MASKS.md);
use explicit local output directories for new measurements.

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
end-to-end Glowroom editing test. Coverage fractions are not accuracy scores.

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
conversions of Meta SAM 2.1 Tiny and Hiera Large. Select `--variant tiny|large`
(default `tiny`); `--verify-only` validates existing files without downloading.
Both variants pin all nine package files by length and SHA-256. Hashing streams
the large encoder weights rather than allocating a weight-sized byte buffer.
`sam2.swift` has `compile` and `run` commands documented in its header. Append
`tiny` or `large` after the existing arguments; omitting the variant preserves
the original Tiny interface. For example, from the repository root:

```sh
python tools/mask-evaluation/sam2-download.py /private/tmp/sam21-large/models --variant large
swiftc -O tools/mask-evaluation/sam2.swift -o /private/tmp/sam21-large/benchmark
/private/tmp/sam21-large/benchmark compile /private/tmp/sam21-large/models /private/tmp/sam21-large/compiled large
/private/tmp/sam21-large/benchmark run /private/tmp/sam21-large/compiled /absolute/private-prompts.json /private/tmp/sam21-large/results gpu large
```

The encoder runs once per photo, while prompt and mask decoders repeat against
its cached features. Both variants use the highest model-scored mask, bilinear
logit restoration and a zero threshold; scores are not comparable accuracy
measurements. Output is segmentation, not a transparency matte. Run native GPU
measurements with an accessible Core ML service; sandbox-limited runs must be
labelled separately. The historical Large follow-up
compared fresh Tiny/Large series on identical proxy bytes and final annotations.

`ben2.py` uses ONNX Runtime in an isolated environment. Pin `onnxruntime==1.31.0`,
plus NumPy/Pillow/psutil, and download `BEN2_Base.onnx` from the revision and
SHA-256 embedded in the script. Specify `--provider cpu|coreml`, `--input-dir`,
`--output-dir`, and `--model`. Choose `--preprocessing pytorch` for the original
Lanczos/ImageNet pipeline, or `onnx-example` to reproduce the published ONNX
example. `--save-raw` retains native prediction arrays before min-max scaling.
The Core ML provider permits CPU fallback and
does not prove exclusive GPU execution. Its load time includes graph setup and
potential Core ML compilation. Keep the upstream preprocessing variants and
reference runs separate; do not mix their measurements.

`ben2_reference.py` audits the pinned original safetensors checkpoint against
the native ONNX paths. It uses strict tensor loading and records the two
preprocessing variants explicitly. Its source/dependency pins are in the script.

The [additional candidate instructions](extra_README.md) describe pinned
BiRefNet GGUF/vision.cpp and EfficientSAM3 EV-M setups, including compatibility
accommodations and external timeouts.

The separate [official EfficientViT-SAM-L1 harness](efficientvit_sam_README.md)
uses current Hugging Face Hub for downloading pinned weights and the verified
official MIT predictor for Float32 MPS/CPU inference. Its 512-pixel encoder,
1024-pixel prompt frame and padding removal differ from the square Core ML
SAM2 pipeline. The harness instructions record the required official source
compatibility pin
and library interface limits; they do not claim Ultralytics/Transformers
inference support for EfficientViT-SAM.

The [Florence-2-large harness](florence2_README.md) tests the exact pinned
Microsoft checkpoint through its original task processor, using a separate
compatible Transformers runtime. It measures text-directed polygons and phrase
grounding boxes separately. The historical comparison used the same private
image proxies and previously saved masks; generated
text, token IDs and full coordinates remain private alongside the masks.

Process RSS includes each harness/runtime and omits some GPU/driver allocations.
First-use measurements do not establish cold-cache performance: system caches
are not purged. Loading, inference, aspect restoration and PNG export have
different scopes across runtimes; compare labelled components, not unqualified
request fields. None of these photographs has a ground-truth alpha matte.

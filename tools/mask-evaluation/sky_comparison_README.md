# Current DETR versus SkyWater-Seg

These offline developer tools compare the currently approved Apple
`DETRResnet50SemanticSegmentationF16` with the sky-specialized
`Realcat/skywater_seg` SegFormer MiT-B2. They do not change the app's installed
model, dependencies, or model selection. Private photographs, derived pictures,
input manifests and weights must remain outside Git.

## Local results, 22 October 2026

The [sanitized measurement summary](sky_comparison_20261022.json) records the
completed runs on the M2 Pro with 12 CPU cores, 19 GPU cores and 16 GiB memory.
The table reports median **pure inference** across the second complete
seven-image pass, with the model already resident. It is not editor latency.

| Model / backend | Second-pass inference | Peak process RSS | Public model files |
| --- | ---: | ---: | ---: |
| Current DETR, native Core ML `.all` | 83.7 ms | 206 MiB | 85.5 MB package |
| Current DETR, Core ML CPU control | 101.2 ms | 423 MiB | same package |
| SkyWater FP16, ONNX/Core ML `ALL` | 109.4 ms | 1012 MiB | 49.9 MB ONNX |
| SkyWater FP32, ONNX CPU, 6 threads | 82.8 ms | 961 MiB | 99.3 MB ONNX |

SkyWater runs comfortably within this machine's memory in this developer
setup. Its CPU path was faster than its Core ML path in this series. Its CPU
time and DETR's accelerated time are effectively similar at this sample size;
this is not evidence of a reliable speed advantage. The separately profiled
SkyWater control observed both Core ML and CPU execution (1036 and 17416
profile node events over 14 predictions). These counts represent fused
partitions and CPU kernels, not comparable original-operation percentages or
proof of a particular GPU/Neural Engine split. All repeated raw masks were
byte-identical within their respective runs.

The first process-local model load took 3.62 s for native DETR and 3.76 s for
SkyWater/Core ML. System caches were not cleared, and these times include
different runtime setup/compilation work. DETR's additional `oneshot` series
reloaded per image as production does: median second-pass request time was
344.6 ms, including model load, proxy preparation, inference, restoration and
refinement, excluding PNG export and production receipt checks/UI work.
SkyWater was not integrated into that native lifecycle, so no end-to-end app
speed claim follows from the resident-model comparison. Its Python/NumPy/ORT
RSS likewise does not predict the memory footprint of a future Swift port.

The controlled native-mask-restoration and shared-refiner visual comparison
showed:

| Local image | Observation |
| --- | --- |
| 1, indoor doorway | Both returned an empty sky mask. |
| 2, misty landscape | Both selected the large sky area; the uncertain mist/horizon boundary differed. No ground truth establishes a winner. |
| 3, snowman and pale roofs | Both separated much of the bright sky from the similarly bright subject/roofs; blurred boundaries remained approximate. |
| 4, toy and printed packaging | Both selected portions of depicted sky. DETR selected a much larger region, including print/packaging details; SkyWater reduced it substantially but still returned a nonempty patch. |
| 5, lake and tree crowns | SkyWater followed parts of the outer crown silhouette and a central gap more closely. Both left substantial unselected sky among fine branches, visible as bright fringes under sky −3 EV. Neither selected the lake reflection. |
| 6, plush subject with blurred outdoor background | Both selected a small upper-left region, with different contours in the strongly blurred background. |
| 7, indoor table and windows | Both returned an empty sky mask. |

The CPU controls did not produce pixel-identical outputs across backends.
SkyWater FP16/Core ML versus FP32/CPU disagreed at no more than 0.0047% of
all image pixels in the official binary masks. DETR CPU versus `.all` disagreed
at no more than 0.51% of all image pixels after thresholding the restored masks, concentrated in the printed
packaging case. The JSON preserves both thresholded disagreement and Gray8
differences; neither is an accuracy score.

The result supports testing SkyWater as an alternative, particularly its CPU
path, but does not justify claiming universally better masks or replacing the
production model automatically. Fine branch/sky holes remain unresolved. The
seven originals were rehashed after the runs and remained unchanged. One first
DETR CPU series overlapped gallery generation, was excluded from performance
conclusions, and was replaced by the isolated CPU series above.

Verification comprised the native optimized harness build, six synthetic native
self-tests (including the actual guided filter and PNG round trip), production
package/model hash checks, numerical interpolation/rounding checks, all seven
real proxies under the four model/backend conditions, repeated masks, the
oneshot lifecycle control, provider profiling, original hash checks and final
diff review. No full app build is required: only standalone tools and
documentation changed; no app source, bundled resource, dependency or build
configuration was modified.

## Reproduce locally

The seven private JPEGs in `Fixtures/LocalTestImages/` are required explicitly.
Use a fresh private output root, an isolated Python 3.11 environment, and the
versions recorded in the measurement report. The comparison used NumPy 2.4.6,
Pillow 13.0.0, psutil 7.2.2, ONNX Runtime 1.31.0 and
opencv-python-headless 4.13.0.92. `prepare.py` applies orientation and sRGB
conversion, limits proxies to 2048 pixels, and checks that originals did not
change. None of the tools uploads photographs.

```sh
python tools/mask-evaluation/prepare.py Fixtures/LocalTestImages /private/tmp/sky-comparison/inputs
bash tools/mask-evaluation/sky_detr_build.sh /private/tmp/sky-comparison/native
```

The native build compiles the real `GlowroomCore` sources, links the production
`AutomaticMaskRefiner.swift`, and extracts the current pixel-buffer conversion,
class lookup and raster conversion directly from `AutomaticMaskService.swift`.
It also extracts the approved package pins from `AutomaticMaskModelStore.swift`.
Source hashes are recorded so a later app change cannot silently be mistaken
for the same comparison. This independent harness build does not modify app
build directories. Native Core ML/Core Image tests require access to macOS GPU
services; sandbox failures must be recorded separately.

Provide the public Apple package that matches those pins. `verify` rejects
missing, changed, unexpected or symlinked package files. `compile` creates a
fresh standalone compiled model without installing it into Glowroom.

```sh
/private/tmp/sky-comparison/native/sky-detr selftest
/private/tmp/sky-comparison/native/sky-detr verify /absolute/DETRResnet50SemanticSegmentationF16.mlpackage
/private/tmp/sky-comparison/native/sky-detr compile /absolute/DETRResnet50SemanticSegmentationF16.mlpackage /private/tmp/sky-comparison/detr.mlmodelc
/private/tmp/sky-comparison/native/sky-detr run /private/tmp/sky-comparison/detr.mlmodelc /private/tmp/sky-comparison/inputs /private/tmp/sky-comparison/detr-all all 2 resident
```

Use `cpu` for an explicit Core ML CPU control. `oneshot` reloads the model for
each image, whereas `resident` retains it across two full seven-image passes.
The app itself releases the sky model after each mask. Harness timings exclude
the production installation-receipt checks and editor/UI work.

SkyWater's explicit `download` command retrieves public files from an immutable
Hugging Face revision and verifies pinned length/SHA-256. `verify` and `run`
work offline. ONNX FP16 and FP32 are separate pinned exports of the same trained
checkpoint, rather than separate competing models.

```sh
python tools/mask-evaluation/skywater.py download --variant fp16 --model /private/tmp/sky-comparison/skywater-fp16.onnx
python tools/mask-evaluation/skywater.py download --variant fp32 --model /private/tmp/sky-comparison/skywater-fp32.onnx
python tools/mask-evaluation/skywater.py run --model /private/tmp/sky-comparison/skywater-fp16.onnx --input-dir /private/tmp/sky-comparison/inputs --output-dir /private/tmp/sky-comparison/skywater-coreml --provider coreml --compute-units all
python tools/mask-evaluation/skywater.py run --model /private/tmp/sky-comparison/skywater-fp32.onnx --input-dir /private/tmp/sky-comparison/inputs --output-dir /private/tmp/sky-comparison/skywater-cpu --provider cpu
```

Run model construction and inference **serially** on this shared machine.
Independent source review and preparation can overlap; simultaneous heavy model
runs would distort latency and peak memory. ONNX Runtime uses six intra-op CPU
threads and one inter-op thread. Core ML controls its own device scheduling.
Configured providers do not establish actual delegation: use a separately
labelled `--profile` control to record Core ML and CPU operator execution.
Core ML partitions may internally use CPU, GPU or Neural Engine; an ORT profile
does not prove which hardware executed each layer.

## Comparable masks and visual inspection

SkyWater follows its pinned upstream RGB/OpenCV/ImageNet preprocessing at
384 × 384. Its official output resizes all four logit channels to the proxy
dimensions with bilinear `align_corners=False`, then takes four-class argmax
and selects sky class 1. `*-raw.png` records that official result.

The existing DETR model returns hard labels at 448 × 448. Glowroom extracts its
metadata-defined `sky (other)` class, bilinearly restores that binary mask,
quantizes it to Gray8, and applies RGB-guided edge refinement. For a controlled
postprocessing comparison, SkyWater additionally saves its native hard sky mask
and an identically defined bilinear Gray8 restoration in
`*-native-bilinear.png`. This alternative is explicitly distinct from its
official logit-restoration output. The production refiner can then process it:

```sh
/private/tmp/sky-comparison/native/sky-detr refine-batch /private/tmp/sky-comparison/inputs /private/tmp/sky-comparison/skywater-coreml /private/tmp/sky-comparison/skywater-refined '{id}-pass{pass}-native-bilinear.png' 2
python tools/mask-evaluation/sky_compare_visuals.py /private/tmp/sky-comparison /private/tmp/sky-comparison/visuals --originals Fixtures/LocalTestImages --models '{"Current DETR":"detr-all/{id}-pass2-refined.png","SkyWater":"skywater-refined/{id}-pass2-refined.png"}'
```

The gallery shows original, red overlay, Gray8 mask and a diagnostic **sky −3 EV**
adjustment in linear sRGB. Optional `--crops` accepts a private JSON mapping
image IDs to pixel rectangles for unscaled detail views. This compositor is not
the complete Glowroom renderer. Coverage, disagreement and inter-model IoU are
diagnostics, not accuracy scores. These photographs have no ground-truth sky
masks. In particular, interpreting a printed sky, a reflection or a window as
editable sky is a product decision as well as a segmentation observation.

Record first prediction, repeated per-image inference, model loading,
preprocessing, restoration, refinement and PNG encoding separately. System
caches are not purged, and preflight reads warm filesystem caches. Model-load
timings therefore do not establish cold-start latency. Process RSS includes
different runtime overheads and can omit GPU/driver allocations; it is not total
device memory. Optional probability export and operator profiling add work and
must not be mixed into an unqualified speed comparison.

Sources: [Apple's model](https://huggingface.co/apple/coreml-detr-semantic-segmentation),
[SkyWater's model](https://huggingface.co/Realcat/skywater_seg), and
[pinned upstream inference](https://github.com/Vincentqyw/skywater/blob/3c86ec7d97c298d06b6352161fe87582c00a291d/skywater_seg/inference.py).

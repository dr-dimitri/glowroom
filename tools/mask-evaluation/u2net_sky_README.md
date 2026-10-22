# Apple DETR versus large U²-Net Sky

This offline comparison evaluates the current Apple
`DETRResnet50SemanticSegmentationF16` against the large `JianyuanWang/skyseg`
ONNX mirror of xiongzhu666's sky-trained U²-Net. The app model and installation
remain unchanged. Photographs, masks, raw profiles, weights and private image
hashes stay outside Git.

## Local results, 22 October 2026

The [sanitized measurement summary](u2net_sky_20261022.json) records fresh,
serial two-pass series on the M2 Pro (12 CPU cores, 19 GPU cores, 16 GiB RAM).
The median below is pure inference over the second complete seven-image pass,
with the model already resident; it is not end-to-end editor latency.

| Model / runtime | Second-pass inference | Peak process RSS | Public files / precision |
| --- | ---: | ---: | --- |
| Apple DETR, native Core ML `.all` | 76.2 ms | 177 MiB | 85.5 MB FP16 package |
| Apple DETR, native Core ML CPU | 103.9 ms | 422 MiB | same package |
| Large U²-Net Sky, ONNX/Core ML `ALL` | 182.7 ms | 688 MiB | 176.0 MB FP32 ONNX |
| Large U²-Net Sky, ONNX CPU, 6 threads | 293.5 ms | 995 MiB | same ONNX |

In this series U²-Net's accelerated inference was about 2.4 times DETR's.
Both fit the machine in this single-model, bounded setup. The larger source
file also uses different precision, so its byte count is not a like-for-like
architecture-size comparison. Native Swift versus Python/NumPy/ORT RSS does
not predict a native U²-Net app integration or total GPU memory.

The separate ORT provider profile observed one Core ML partition per prediction
(14 events over 14 predictions) and no CPU EP execution events. This establishes
delegation to Core ML, not which CPU/GPU/ANE unit Core ML used internally.
U²-Net CPU and Core ML produced byte-identical restored hard masks for all seven
images, with maximum native Float32 probability difference below 0.00000418. All
repeated raw masks were byte-identical within each model/backend series.

The first process-local model loads were 0.144 s for DETR `.all` and 1.243 s for
U²-Net/Core ML. These followed earlier same-device tests and do not measure cold
caches. The app's per-mask model reload lifecycle was not benchmarked anew;
resident model results must not be presented as production request latency.

Visual inspection with the same production refiner and sky −3 EV diagnostic:

| Local image | Observation |
| --- | --- |
| 1, indoor doorway | Both hard masks were empty. U²-Net's largest raw sigmoid value was only 0.0539. |
| 2, misty landscape | Both selected the broad sky, with different uncertain horizon contours. |
| 3, snowman and bright roofs | Both protected the bright subject. Their approximate contours differed around the blurred pale roof/background. |
| 4, toy and packaging | U²-Net's hard mask was empty (raw maximum 0.0412). DETR selected a large portion of the depicted/printed sky and some packaging details. |
| 5, lake and tree crowns | U²-Net followed the outer crown and spruce-tip structure in more detail and selected more visible gaps. DETR mostly followed a smooth crown envelope. U²-Net still left bright mixed-pixel fringes and missed finer holes; neither selected the lake reflection. |
| 6, strongly blurred outdoor background | U²-Net's upper-left sky selection was more fragmented, leaving a conspicuous unselected bright patch where DETR's selection was continuous. |
| 7, indoor table and windows | Both hard masks were empty. U²-Net's raw maximum was 0.1611. |

A separate soft-output/refiner gallery preserves U²-Net's continuous prediction
without thresholding. On the tree detail it softens the transition and preserves
some graded gaps, but does not remove all bright fringes. The detailed crown
advantage is also visible in the hard-mask comparison, so it is not solely an
effect of changing from labels to soft opacity. No calibrated alpha or
quantitative accuracy advantage is established without reference masks.

The producer's min/max visualization would still stretch weak responses in
images 1, 4 and 7 to 255. Its fraction above half is approximately 0.0236%,
0.0953% and 0.00766% of all image pixels respectively. The fixed-threshold main
comparison avoids interpreting those low-confidence tails as sky. The PNG/NPY
diagnostics retain both policies explicitly.

The comparison supports large U²-Net as a more detailed sky alternative on
these tree images, with higher inference cost and a visible blurred-background
failure. It does not establish a universal winner or change the app model.
All seven original and proxy hashes matched after the runs. Validation included
the pinned ONNX checker/shape/fusion/sigmoid audit, 20 synthetic preprocessing,
threshold/restoration/range/min-max checks, fresh native Apple controls, two
complete passes per model/backend, provider profiling, hard/soft guided-filter
galleries, and independent final diff/numeric/privacy review.

## Model contract

The public ONNX export is pinned to Hugging Face revision
`3ba8c6df1d9ba9ff26f637c7ba9568ac11a9aa7f`, 175,997,079 bytes, SHA-256
`ab9c34c64c3d821220a2886a4a06da4642ffa14d5b30e8d5339056a089aa1d39`.
An independent ONNX 1.23.2 audit/checker confirms 43,981,069 Float32 initializer
elements, one `[1,3,320,320]` input and seven `[1,1,320,320]` sigmoid outputs.
Output `1959` is the fused head, used alone as upstream does. Do not apply a
second sigmoid. This is the full U²-Net, distinct from the roughly 2 MB U²-NetP
demo; no identity with the author's private commercial model is claimed.

Preprocessing matches the
[pinned upstream function](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing/blob/1f7811b32b64ddc957269defff84bc87a3f0b74f/onnx_interence.py):
OpenCV `INTER_LINEAR` full-frame RGB resize to 320 × 320, division by 255,
ImageNet mean/std (including the NumPy Float64 intermediate), NCHW Float32.
Unlike some generic U²-Net examples, this model does not divide by the image
maximum. The standalone demo's earlier `pyrDown` loop is omitted because both
models receive the same standardized proxy bytes.

The main controlled comparison thresholds the native unstretched sigmoid at
0.5, then uses the same bilinear Gray8 restoration and production RGB-guided
refiner as DETR. The threshold is fixed, not optimized for these photographs.
Soft outputs are saved separately and are not assumed to be compositing alpha.
The producer's per-image min/max visualization is also saved separately: it
can magnify weak residual responses and divides by zero for constant outputs.
The harness guards and records that undefined case.

## Reproduce locally

Use the seven private JPEGs explicitly required by
[the masking evaluation guide](README.md). They are absent in CI/fresh checkouts.
The measured run reused exact prior sRGB proxy bytes, bounded to 2048 pixels,
after verifying proxy and original hashes again. Fresh preparation is supported.
Use Python 3.11, NumPy 2.4.6, Pillow 13.0.0, psutil 7.2.2, ONNX Runtime 1.31.0
and opencv-python-headless 4.13.0.92 in an isolated environment.

```sh
python tools/mask-evaluation/prepare.py Fixtures/LocalTestImages /private/tmp/u2net-sky/inputs
bash tools/mask-evaluation/sky_detr_build.sh /private/tmp/u2net-sky/native
/private/tmp/u2net-sky/native/sky-detr verify /absolute/DETRResnet50SemanticSegmentationF16.mlpackage
/private/tmp/u2net-sky/native/sky-detr compile /absolute/DETRResnet50SemanticSegmentationF16.mlpackage /private/tmp/u2net-sky/detr.mlmodelc
/private/tmp/u2net-sky/native/sky-detr run /private/tmp/u2net-sky/detr.mlmodelc /private/tmp/u2net-sky/inputs /private/tmp/u2net-sky/detr-all all 2 resident
python tools/mask-evaluation/u2net_sky.py download --model /private/tmp/u2net-sky/skyseg.onnx
python tools/mask-evaluation/u2net_sky.py run --model /private/tmp/u2net-sky/skyseg.onnx --input-dir /private/tmp/u2net-sky/inputs --output-dir /private/tmp/u2net-sky/u2net-coreml --provider coreml --compute-units all --save-official --save-probability
python tools/mask-evaluation/u2net_sky.py run --model /private/tmp/u2net-sky/skyseg.onnx --input-dir /private/tmp/u2net-sky/inputs --output-dir /private/tmp/u2net-sky/u2net-cpu --provider cpu --save-official --save-probability
/private/tmp/u2net-sky/native/sky-detr refine-batch /private/tmp/u2net-sky/inputs /private/tmp/u2net-sky/u2net-coreml /private/tmp/u2net-sky/u2net-refined '{id}-pass{pass}-raw.png' 2
python tools/mask-evaluation/sky_compare_visuals.py /private/tmp/u2net-sky /private/tmp/u2net-sky/visuals --originals Fixtures/LocalTestImages --models '{"Apple DETR":"detr-all/{id}-pass2-refined.png","Large U2Net Sky":"u2net-refined/{id}-pass2-refined.png"}'
```

Use `cpu` in the native DETR run for its CPU control. The U²-Net `download`
command retrieves only public weights; `verify` and `run` are offline. Every
output directory must be fresh. The tool imports neutral hashing, memory,
bounded-input and restoration helpers from `skywater.py`, not its inference.
Run model series serially to avoid timing/memory contention; independent code
research and review may overlap. ORT uses six intra-op threads and one inter-op
thread; Core ML schedules its own parallel work.

Output policy:

- `*-raw.png`: native decision at raw sigmoid ≥ 0.5, restored like the app.
- `*-native-raw.png`: the native binary decision before restoration.
- `*-soft.png`: unstretched soft prediction, separate from the main comparison.
- `*-official-minmax.png`: separately labelled producer visualization.
- `*-native-sky-probability.npy`: optional original Float32 output for diagnostics.

## Measurement limits and validation

Both models remain resident across two complete seven-image passes, without a
discarded warmup. Compare the second-pass pure inference separately from model
load, preparation, restoration, refinement and export. Optional diagnostic
exports add postprocessing/I/O work, not pure inference. The app itself reloads
DETR per mask; these timings exclude receipt checks, UI and preview/RAW creation.
Input preflight warms filesystem caches; OS/driver caches are not purged.

Python/NumPy/ORT and native Swift process RSS include different overhead and
omit some GPU/driver allocations. Neither predicts a future native U²-Net
integration. Native ImageIO decode can be deferred into drawing, so individual
decode/preprocessing components are not directly comparable across runtimes.
Use a separate `--profile` control to establish actual ORT providers; Core ML
may retain CPU partitions, and provider labels do not prove GPU/ANE execution.

The gallery's sky −3 EV adjustment is a linear-sRGB diagnostic, not the full
app renderer. There are no ground-truth masks; coverage and inter-model IoU are
not accuracy. Printed sky, reflections and windows need explicit interpretation.
The [prior comparison](sky_comparison_README.md) describes the unchanged native
build, source extraction and real production refiner in detail. Their source
hashes and Apple model pins were rechecked before this follow-up.

Only standalone tools and documentation change, so no full app build is needed.
New preprocessing, threshold/normalization policy, numeric/error guards and final
results receive independent review. Original hashes are checked after the runs.

Sources: [public large mirror](https://huggingface.co/JianyuanWang/skyseg),
[upstream sky project](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing),
[reference architecture](https://github.com/xuebinqin/U-2-Net),
[Apple model](https://huggingface.co/apple/coreml-detr-semantic-segmentation).

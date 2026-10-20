# Additional offline mask candidates

These developer harnesses evaluate optional candidates; they are not linked into
PicEdit and do not change its model selection. Use the prepared, oriented sRGB
PNGs and the private manifest made by `prepare.py`. Do not commit photographs,
weights, or result masks. Run one model process at a time; contention would make
latency and memory comparisons unreliable.

## BiRefNet standard F16 GGUF

The test uses [Acly/vision.cpp](https://github.com/Acly/vision.cpp) revision
`26a752912d49f6c4ff4545b35a1bdf7400d349ed` with its pinned ggml submodule
`5fde0fae463cb6def4747d05dcadb21495b4ce93`. Configure a separate build with
`-D GGML_METAL=OFF -D VISP_TESTS=OFF -D CMAKE_BUILD_TYPE=Release` and build with at
most four jobs. CMake and Ninja can be installed in an isolated Python venv;
the project also fetches the public `stb` dependency during configuration.

The weight file is `Acly/BiRefNet-GGUF/BiRefNet-F16.gguf` at revision
`4f6018e2f35cedf26c8ddf0fec1475252f8ba280`, SHA-256
`5d5fd824c8fb2c1a65fc4345458b2e78777d949418385ea7bba5a9f104364d77`.
This is **standard BiRefNet at 1024 square pixels, not HR-matting at 1920**.
Changing the format does not itself improve model quality. The CPU runtime
converts the resident weights to its preferred F32 representation, so the
440 MB F16 download size does not represent resident memory.

With `vision.cpp` and its `build` directory beneath the temporary `extra/gguf`
directory used for this evaluation:

```sh
clang++ -std=c++20 -O3 tools/mask-evaluation/extra_gguf.cpp \
  -I/private/tmp/picedit-mask-evaluation-20261020/extra/gguf/vision.cpp/include \
  -I/private/tmp/picedit-mask-evaluation-20261020/extra/gguf/vision.cpp/depend/llama/ggml/include \
  -L/private/tmp/picedit-mask-evaluation-20261020/extra/gguf/build/lib \
  -lvisioncpp -lggml -lggml-base \
  -Wl,-rpath,/private/tmp/picedit-mask-evaluation-20261020/extra/gguf/build/lib \
  -o /private/tmp/picedit-mask-evaluation-20261020/extra/gguf/extra_gguf

VECLIB_MAXIMUM_THREADS=4 /private/tmp/picedit-mask-evaluation-20261020/extra/gguf/extra_gguf \
  /private/tmp/picedit-mask-evaluation-20261020/extra/gguf/BiRefNet-F16.gguf \
  /private/tmp/picedit-mask-evaluation-20261020/inputs \
  /private/tmp/picedit-mask-evaluation-20261020/results/gguf-cpu 4
```

The weights remain loaded for the complete run. The first photograph is repeated
once to separate the first graph allocation from subsequent work. `pipelineSeconds`
includes model preprocessing, graph setup when needed, inference, and restoration
to input size. It is not directly comparable to Core ML's inference-only time;
compare request scopes instead. The report records process peak RSS, not total
system memory, alongside fractional output coverage.

## EfficientSAM3 EV-M Stage 3

Use [SimonZeng7108/efficientsam3](https://github.com/SimonZeng7108/efficientsam3)
revision `bd0936c788fed8d51fa799437f05abd97b401b06`, with the public
`Simon7108528/EfficientSAM3/efficientsam3_ft/efficientsam3_efficientvit.pt`
checkpoint at `85b05896928f974e308f889d7ccb2eefc069de98`, SHA-256
`086b04b2e7da7cc98aa4621b70c7291608aa9d187357b98d03bd4d6533ed5a17`.
This is EfficientViT-B1 plus MobileCLIP-S0 with 16 text tokens, not the much
larger SAM3-LiteText model. Prompts come from the manifest's explicit English
`target` field. They are manually chosen test targets, not generated grounding.

The locally available Python 3.11 / PyTorch 2.5 / torchvision 0.20 environment
was reused read-only through a `.pth` in a new isolated venv. Additional packages
were installed only in that venv: `timm==1.0.17`, `ftfy==6.1.1`, `iopath`,
`einops`, `hydra-core`, `pycocotools`, `psutil`, `scipy`, and
`opencv-python-headless==4.11.0.86`. OpenCV avoids importing a CUDA-only video
decoder through upstream training modules. The upstream project metadata asks
for Python >=3.12 and its stage1 extra for torch >=2.7; using the older existing
versions is a test accommodation and must be reported with results.

```sh
/private/tmp/picedit-mask-evaluation-20261020/extra/efficientsam3/venv/bin/python \
  tools/mask-evaluation/extra_efficientsam3.py \
  --repo /private/tmp/picedit-mask-evaluation-20261020/extra/efficientsam3/repo \
  --checkpoint /private/tmp/picedit-mask-evaluation-20261020/extra/efficientsam3/efficientsam3_efficientvit.pt \
  --manifest /private/tmp/picedit-mask-evaluation-20261020/prompts.json \
  --output /private/tmp/picedit-mask-evaluation-20261020/results/efficientsam3-cpu \
  --device cpu --threads 4
```

Use an external process timeout when testing uncertain backends. `--limit 1`
performs only the first photograph plus its repeat. `--device mps` explicitly
moves the model to MPS because this upstream builder only moves CUDA models
itself. MPS availability and unsupported operations must be checked in the actual
test; imports alone do not validate that execution path.

The harness rejects missing model tensors instead of allowing the upstream
loader's permissive partial initialization. It saves the union of binary
instance masks. The separate probability image is a diagnostic segmentation
confidence map and must not be presented as a calibrated matting alpha.
The harness pins upstream's global device helper to the selected device before
construction, because its positional cache otherwise prefers MPS even for an
explicit CPU builder request. This is a local process accommodation, without
changing the upstream checkout.

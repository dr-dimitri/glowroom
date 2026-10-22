#!/usr/bin/env python3
"""Pinned, local SkyWater-Seg ONNX comparison on the seven private proxies.

Only the explicit ``download`` command accesses the network, to retrieve public
weights. ``run`` is offline and never uploads images. Run model processes
serially: concurrent benchmarks would contend for the same CPU/GPU and memory.
The preprocessing follows the pinned upstream ONNXRuntimeInference implementation
(OpenCV INTER_LINEAR, RGB / 255, ImageNet normalization, 384 x 384).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import resource
import statistics
import sys
import threading
import time
import urllib.request
from pathlib import Path


REVISION = "dac255883ec5faf508561a47172096bfd8708db0"
SOURCE_REVISION = "3c86ec7d97c298d06b6352161fe87582c00a291d"
SOURCE_URL = f"https://github.com/Vincentqyw/skywater/blob/{SOURCE_REVISION}/skywater_seg/inference.py"
MODELS = {
    "fp32": {
        "filename": "skywater_segformer_b2_fp32.onnx",
        "bytes": 99310780,
        "sha256": "e4e9a6927c2d910c3243f86e392b18da715b41c03e6e6f41672f8f6b8eaa71b5",
    },
    "fp16": {
        "filename": "skywater_segformer_b2_fp16.onnx",
        "bytes": 49867699,
        "sha256": "a4f518e6ace87b3ee473ea2578d00f0fb5f7bf8e4e6a3a49ae368c048c4e47c3",
    },
}
SIDE = 384
EXPECTED_INPUTS = tuple(f"test_picture{i}.png" for i in range(1, 8))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_model(path: Path, variant: str | None = None) -> tuple[str, dict]:
    size = path.stat().st_size
    digest = sha256(path)
    candidates = {variant: MODELS[variant]} if variant else MODELS
    for key, pin in candidates.items():
        if size == pin["bytes"] and digest == pin["sha256"]:
            return key, pin
    raise ValueError(f"Model differs from the pinned official graph (bytes={size}, SHA-256={digest})")


def download_model(path: Path, variant: str) -> None:
    """Stream public weights into a fresh sibling file; publish only after verification."""
    if path.exists():
        verify_model(path, variant)
        print(json.dumps({"status": "verified-existing", "model": str(path), **MODELS[variant]}))
        return
    pin = MODELS[variant]
    url = f"https://huggingface.co/Realcat/skywater_seg/resolve/{REVISION}/{pin['filename']}"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    # Exclusive creation preserves another download's staging file.
    with temporary.open("xb") as destination:
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Glowroom-local-mask-evaluation/1"})
            digest = hashlib.sha256()
            total = 0
            with urllib.request.urlopen(request, timeout=120) as response:
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > pin["bytes"]:
                        raise ValueError("Download exceeds pinned model length")
                    digest.update(block)
                    destination.write(block)
            if total != pin["bytes"] or digest.hexdigest() != pin["sha256"]:
                raise ValueError("Download failed pinned length/SHA-256 verification")
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    # Another process could have completed the same destination meanwhile.
    # Hard-link creation is atomic and refuses to replace an existing file.
    try:
        path.hardlink_to(temporary)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps({"status": "downloaded-verified", "model": str(path), "url": url, **pin}))


class MemorySampler:
    """Sample process RSS; GPU and driver allocations may be absent."""

    def __init__(self, psutil) -> None:
        self.process = psutil.Process()
        self.stop_event = threading.Event()
        self.peak = self.process.memory_info().rss
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self) -> None:
        while not self.stop_event.wait(0.02):
            self.peak = max(self.peak, self.process.memory_info().rss)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join()
        self.peak = max(self.peak, self.process.memory_info().rss)


def validate_inputs(directory: Path, Image) -> list[dict]:
    paths = sorted(directory.glob("*.png"))
    if {path.name for path in paths} != set(EXPECTED_INPUTS):
        raise ValueError(f"Input directory must contain exactly {EXPECTED_INPUTS}")
    manifest = []
    for name in EXPECTED_INPUTS:
        path = directory / name
        with Image.open(path) as image:
            if image.format != "PNG" or image.mode != "RGB":
                raise ValueError(f"{name}: expected a prepared RGB PNG proxy")
            if min(image.size) < 1 or max(image.size) > 2048:
                raise ValueError(f"{name}: expected a prepared proxy bounded to 2048 pixels")
            if image.getexif().get(274, 1) != 1:
                raise ValueError(f"{name}: apply EXIF orientation before evaluation")
            image.load()  # Validate every complete file before loading the model.
            manifest.append({"image": name, "width": image.width, "height": image.height,
                             "bytes": path.stat().st_size, "sha256": sha256(path)})
    return manifest


def resize_bilinear(array, width: int, height: int, np):
    """Float32 bilinear half-pixel coordinates, matching align_corners=False.

    Leading dimensions are preserved, so all four logit planes can be resized
    together without independently maintained interpolation implementations.
    """
    source_height, source_width = array.shape[-2:]
    x = np.maximum((np.arange(width, dtype=np.float32) + np.float32(0.5))
                   * np.float32(source_width / width) - np.float32(0.5), np.float32(0))
    y = np.maximum((np.arange(height, dtype=np.float32) + np.float32(0.5))
                   * np.float32(source_height / height) - np.float32(0.5), np.float32(0))
    x0 = np.minimum(x.astype(np.int32), source_width - 1)
    y0 = np.minimum(y.astype(np.int32), source_height - 1)
    x1 = np.minimum(x0 + 1, source_width - 1)
    y1 = np.minimum(y0 + 1, source_height - 1)
    wx = x - x0.astype(np.float32)
    wy = (y - y0.astype(np.float32))[:, None]
    horizontal = array[..., x0] * (1 - wx) + array[..., x1] * wx
    return (horizontal[..., y0, :] * (1 - wy) + horizontal[..., y1, :] * wy).astype(np.float32)


def restore_native_like_app(native_mask, width: int, height: int, np):
    """Match AutomaticMaskService.sampled: Double arithmetic, round positive ties up.

    Keep the multiplication/division order and clamp both coordinate ends, as
    the production Swift converter does. Coverage remains in [0,1] until the
    final byte quantization, rather than interpolating pre-scaled 255 values.
    """
    source_height, source_width = native_mask.shape
    x = np.clip((np.arange(width, dtype=np.float64) + 0.5) * source_width / width - 0.5,
                0, source_width - 1)
    y = np.clip((np.arange(height, dtype=np.float64) + 0.5) * source_height / height - 0.5,
                0, source_height - 1)
    x0, y0 = x.astype(np.int32), y.astype(np.int32)
    x1, y1 = np.minimum(x0 + 1, source_width - 1), np.minimum(y0 + 1, source_height - 1)
    fx, fy = x - x0, (y - y0)[:, None]
    coverage = native_mask.astype(np.float64) / 255
    horizontal = coverage[:, x0] * (1 - fx) + coverage[:, x1] * fx
    restored = horizontal[y0] * (1 - fy) + horizontal[y1] * fy
    return np.floor(np.clip(255 * restored, 0, 255) + 0.5).astype(np.uint8)


def softmax(logits, np):
    shifted = logits - logits.max(axis=0, keepdims=True)
    probabilities = np.exp(shifted)
    probabilities /= probabilities.sum(axis=0, keepdims=True)
    if not np.isfinite(probabilities).all() or probabilities.min() < 0 or probabilities.max() > 1:
        raise ValueError("Invalid SkyWater probabilities")
    return probabilities


def write_report(directory: Path, report: dict) -> None:
    temporary = directory / "results.json.tmp"
    temporary.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    temporary.replace(directory / "results.json")


def evaluate(args, report: dict, np, cv2, ort, Image, psutil) -> None:
    variant, pin = verify_model(args.model)
    report.update({"variant": variant, "modelBytes": pin["bytes"], "modelSHA256": pin["sha256"],
                   "modelURL": f"https://huggingface.co/Realcat/skywater_seg/blob/{REVISION}/{pin['filename']}"})
    available = ort.get_available_providers()
    if args.provider == "coreml" and "CoreMLExecutionProvider" not in available:
        raise RuntimeError("Requested CoreML provider is unavailable; run --provider cpu explicitly")
    options = ort.SessionOptions()
    options.intra_op_num_threads = args.threads
    options.inter_op_num_threads = 1
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.enable_profiling = args.profile
    options.profile_file_prefix = str(args.output_dir / "ort-profile")
    providers = ["CPUExecutionProvider"]
    if args.provider == "coreml":
        providers.insert(0, ("CoreMLExecutionProvider", {
            "ModelFormat": "MLProgram", "MLComputeUnits": "ALL" if args.compute_units == "all" else "CPUAndGPU",
            "RequireStaticInputShapes": "1",
        }))
    started = time.perf_counter()
    session = ort.InferenceSession(str(args.model), options, providers=providers)
    session.disable_fallback()  # Runtime errors must not silently restart on another provider.
    report["modelLoadSeconds"] = time.perf_counter() - started
    report["sessionProviders"] = session.get_providers()
    report["providerOptions"] = session.get_provider_options()
    if args.provider == "coreml" and "CoreMLExecutionProvider" not in session.get_providers():
        raise RuntimeError("ORT silently created a CPU session after CoreML initialization failed")
    inputs, outputs = session.get_inputs(), session.get_outputs()
    if len(inputs) != 1 or len(outputs) != 1:
        raise ValueError("Expected exactly one model input and output")
    input_meta = inputs[0]
    if len(input_meta.shape) != 4 or any(isinstance(dim, int) and dim != expected
                                        for dim, expected in zip(input_meta.shape, [1, 3, SIDE, SIDE])):
        raise ValueError(f"Unexpected SkyWater input shape: {input_meta.shape}")
    dtypes = {"tensor(float)": np.float32, "tensor(float16)": np.float16}
    if input_meta.type not in dtypes:
        raise ValueError(f"Unexpected input type: {input_meta.type}")
    report["inputContract"] = {"name": input_meta.name, "shape": input_meta.shape, "type": input_meta.type}
    report["outputContract"] = {"name": outputs[0].name, "shape": outputs[0].shape, "type": outputs[0].type}
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    report["measurements"] = []
    first_masks = {}
    for pass_index in range(1, args.repeats + 1):
        for manifest in report["inputs"]:
            path = args.input_dir / manifest["image"]
            request_started = time.perf_counter()
            # Read on every pass to include proxy decoding. No hidden image/tensor cache.
            with Image.open(path) as image:
                image.load()
                rgb = np.asarray(image, dtype=np.uint8)
                width, height = image.size
            read_ended = time.perf_counter()
            resized = cv2.resize(rgb, (SIDE, SIDE), interpolation=cv2.INTER_LINEAR)
            normalized = (resized.astype(np.float32) / np.float32(255) - mean) / std
            tensor = np.ascontiguousarray(normalized.transpose(2, 0, 1)[None], dtype=dtypes[input_meta.type])
            if not np.isfinite(tensor).all():
                raise ValueError(f"Non-finite input tensor for {path.name}")
            preprocess_ended = time.perf_counter()
            output = session.run([outputs[0].name], {input_meta.name: tensor})[0]
            inference_ended = time.perf_counter()
            if output.ndim != 4 or output.shape[0:2] != (1, 4) or min(output.shape[2:]) < 1:
                raise ValueError(f"Unexpected logits shape: {output.shape}")
            if not np.isfinite(output).all():
                raise ValueError("SkyWater returned non-finite logits")
            logits = output[0].astype(np.float32)
            native_mask = (logits.argmax(axis=0) == 1).astype(np.uint8) * 255
            # App-comparable alternative: restore the hard native label mask,
            # as the existing DETR path does, before the shared edge refiner.
            native_bilinear = restore_native_like_app(native_mask, width, height, np)
            restored_logits = resize_bilinear(logits, width, height, np)
            labels = restored_logits.argmax(axis=0)
            mask = (labels == 1).astype(np.uint8) * 255
            soft = softmax(restored_logits, np)[1] if args.save_soft else None
            native_probability = softmax(logits, np)[1] if args.save_probability else None
            diagnostics = {
                "logitsShape": list(output.shape), "logitsMinimum": float(logits.min()),
                "logitsMaximum": float(logits.max()),
                "skyFraction": float(np.mean(labels == 1)),
                "classFractions": {str(label): float(np.mean(labels == label)) for label in range(4)},
            }
            postprocess_ended = time.perf_counter()
            prefix = f"{path.stem}-pass{pass_index}"
            mask_path = args.output_dir / f"{prefix}-raw.png"
            native_path = args.output_dir / f"{prefix}-native-raw.png"
            native_bilinear_path = args.output_dir / f"{prefix}-native-bilinear.png"
            Image.fromarray(mask).save(mask_path)
            Image.fromarray(native_mask).save(native_path)
            Image.fromarray(native_bilinear).save(native_bilinear_path)
            if soft is not None:
                Image.fromarray(np.clip(soft * 255, 0, 255).astype(np.uint8)).save(
                    args.output_dir / f"{prefix}-soft.png")
            if native_probability is not None:
                np.save(args.output_dir / f"{prefix}-native-sky-probability.npy", native_probability)
            encode_ended = time.perf_counter()
            for target, expected in [(mask_path, mask), (native_path, native_mask),
                                     (native_bilinear_path, native_bilinear)]:
                with Image.open(target) as decoded:
                    if decoded.mode != "L" or not np.array_equal(np.asarray(decoded), expected):
                        raise ValueError(f"Mask encoding failed round-trip validation: {target}")
            mask_digest = sha256(mask_path)
            if pass_index == 1:
                first_masks[path.name] = mask_digest
            measurement = {
                "image": path.name, "pass": pass_index, "width": width, "height": height,
                "firstPredictionInProcess": pass_index == 1 and path.name == EXPECTED_INPUTS[0],
                "modelRetained": True,
                "inputReadSeconds": read_ended - request_started,
                "preprocessSeconds": preprocess_ended - read_ended,
                "inferenceSeconds": inference_ended - preprocess_ended,
                "postprocessSeconds": postprocess_ended - inference_ended,
                "requestSecondsExcludingLoadAndWrites": postprocess_ended - request_started,
                "encodeAndWriteSeconds": encode_ended - postprocess_ended,
                "requestSecondsIncludingWrites": encode_ended - request_started,
                "outputVerificationSeconds": time.perf_counter() - encode_ended,
                "processRSSBytesAfterRequest": psutil.Process().memory_info().rss,
                "rawPath": str(mask_path), "rawSHA256": mask_digest,
                "nativeRawPath": str(native_path), "nativeRawSHA256": sha256(native_path),
                "nativeBilinearPath": str(native_bilinear_path),
                "nativeBilinearSHA256": sha256(native_bilinear_path),
                "identicalRawToFirstPass": mask_digest == first_masks[path.name], **diagnostics,
            }
            report["measurements"].append(measurement)
            print(json.dumps(measurement, allow_nan=False), flush=True)
            write_report(args.output_dir, report)
    if args.profile:
        profile_path = session.end_profiling()
        report["ortProfilePath"] = profile_path
        counts = {}
        for event in json.loads(Path(profile_path).read_text()):
            provider = event.get("args", {}).get("provider")
            if provider:
                counts[provider] = counts.get(provider, 0) + 1
        report["profileNodeEventCountsByProvider"] = counts
        report["cpuNodeExecutionObserved"] = counts.get("CPUExecutionProvider", 0) > 0
        report["coreMLNodeExecutionObserved"] = counts.get("CoreMLExecutionProvider", 0) > 0
    else:
        report["cpuNodeExecutionObserved"] = args.provider == "cpu" if args.provider == "cpu" else None
        report["coreMLNodeExecutionObserved"] = None
    repeated = [m for m in report["measurements"] if m["pass"] > 1]
    for name in ["inputReadSeconds", "preprocessSeconds", "inferenceSeconds", "postprocessSeconds",
                 "encodeAndWriteSeconds", "requestSecondsExcludingLoadAndWrites"]:
        report[f"median{name[0].upper() + name[1:]}RepeatedImages"] = statistics.median(m[name] for m in repeated)
    report["allRepeatedRawMasksIdentical"] = all(m["identicalRawToFirstPass"] for m in repeated)
    report["status"] = "complete"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    downloader = commands.add_parser("download", help="Explicitly download and verify public pinned weights")
    downloader.add_argument("--variant", choices=tuple(MODELS), default="fp32")
    downloader.add_argument("--model", type=Path, required=True)
    verifier = commands.add_parser("verify", help="Verify local model length and SHA-256; no network")
    verifier.add_argument("--model", type=Path, required=True)
    runner = commands.add_parser("run", help="Offline sequential benchmark on exactly seven prepared proxies")
    runner.add_argument("--model", type=Path, required=True)
    runner.add_argument("--input-dir", type=Path, required=True)
    runner.add_argument("--output-dir", type=Path, required=True)
    runner.add_argument("--provider", choices=("coreml", "cpu"), default="coreml")
    runner.add_argument("--compute-units", choices=("all", "cpu-gpu"), default="all",
                        help="CoreML hardware permission: all permits CPU/GPU/ANE like current DETR; cpu-gpu excludes ANE")
    runner.add_argument("--threads", type=int, default=6)
    runner.add_argument("--repeats", type=int, default=2)
    runner.add_argument("--profile", action="store_true", help="Record operator execution providers; adds timing overhead")
    runner.add_argument("--save-probability", action="store_true", help="Also save native float32 sky softmax probabilities as NPY")
    runner.add_argument("--save-soft", action="store_true", help="Also save restored sky softmax as Gray8 PNG")
    args = parser.parse_args()
    if args.command == "download":
        download_model(args.model, args.variant)
        return 0
    if args.command == "verify":
        variant, pin = verify_model(args.model)
        print(json.dumps({"status": "verified", "variant": variant, "revision": REVISION, **pin}))
        return 0
    if args.threads < 1 or args.repeats < 2:
        parser.error("--threads must be positive and --repeats must be at least 2 complete passes")
    # Download/verification commands need only stdlib; benchmark dependencies stay local.
    import cv2
    import numpy as np
    import onnxruntime as ort
    import PIL
    import psutil
    from PIL import Image

    ort.disable_telemetry_events()
    manifest = validate_inputs(args.input_dir, Image)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    report = {
        "schemaVersion": 1, "model": "Realcat/skywater_seg SegFormer MiT-B2",
        "revision": REVISION, "sourceRevision": SOURCE_REVISION, "sourceURL": SOURCE_URL,
        "runtime": "Python harness / native ONNX Runtime C++", "pythonVersion": sys.version,
        "onnxruntimeVersion": ort.__version__, "numpyVersion": np.__version__,
        "opencvVersion": cv2.__version__, "pillowVersion": PIL.__version__, "psutilVersion": psutil.__version__,
        "platform": platform.platform(), "machine": platform.machine(),
        "inputs": manifest, "inputSide": SIDE, "classes": {0: "background", 1: "sky", 2: "water", 3: "person"},
        "requestedProvider": args.provider, "requestedCoreMLComputeUnits": args.compute_units,
        "availableProviders": ort.get_available_providers(),
        "threads": args.threads, "repeats": args.repeats, "profilingEnabled": args.profile,
        "saveNativeProbability": args.save_probability, "saveSoftGray8": args.save_soft,
        "preprocessing": "RGB uint8; OpenCV INTER_LINEAR stretch to 384x384; float32 /255; ImageNet mean/std; NCHW",
        "rawMaskPostprocessing": "Float32 bilinear logits to proxy dimensions, align_corners=False; four-class argmax == sky (1); binary Gray8",
        "nativeRawPostprocessing": "Four-class argmax of unresized native logits == sky (1); binary Gray8 for shared app refiner",
        "nativeBilinearPostprocessing": "Native binary sky mask restored with production Swift sampled() Double coordinates and half-pixel bilinear coverage; Gray8 rounded ties up; input to shared app refiner",
        "softPostprocessing": "Softmax across four classes; native NPY or restored-logit Gray8; no min-max normalization",
        "cpuFallback": "CPU graph partitions allowed with CoreML; no silent runtime retry; profile required to establish executed providers",
        "status": "running",
        "limitations": [
            "Developer Python/ORT harness, not a native Swift/Core ML app benchmark.",
            "Model processes and image predictions are serial to avoid benchmark contention.",
            "Model remains resident across both complete seven-image passes; no discarded warmup.",
            "First model load includes runtime setup/Core ML compilation; system caches are not flushed.",
            "Process RSS includes Python/runtime; GPU/driver memory may be absent.",
            "CoreML defaults to ALL (CPU/GPU/ANE allowed); configured providers do not prove actual GPU/ANE execution.",
            "Profiling counts CoreML partitions, not hardware compute units, and adds timing overhead.",
            "Prepared oriented sRGB proxy decoding is timed; original JPEG/RAW development is excluded.",
            "Input preflight decodes all proxies before timing; these measurements do not represent cold filesystem caches.",
            "Optional probability/soft exports add measured postprocessing and output costs.",
            "Postprocessing/output timings include both official restored-logit masks and app-comparable native-mask restoration.",
            "Masks/probabilities are semantic sky predictions, not calibrated image-compositing alpha.",
        ],
    }
    memory = MemorySampler(psutil)
    memory.start()
    started = time.perf_counter()
    exit_code = 0
    try:
        evaluate(args, report, np, cv2, ort, Image, psutil)
    except KeyboardInterrupt:
        report.update({"status": "interrupted", "error": "KeyboardInterrupt"})
        exit_code = 130
    except Exception as error:
        report.update({"status": "failed", "error": f"{type(error).__name__}: {error}"})
        print(report["error"], file=sys.stderr, flush=True)
        exit_code = 1
    finally:
        memory.stop()
        report["totalProcessWorkSeconds"] = time.perf_counter() - started
        report["sampledPeakProcessRSSBytes"] = memory.peak
        high_water = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        report["peakProcessRSSBytes"] = high_water if sys.platform == "darwin" else high_water * 1024
        write_report(args.output_dir, report)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Offline BEN2 Base evaluation using the official pinned ONNX graph.

Developer-only Python harness; inference runs in native ONNX Runtime. This is
not an integration or performance measurement of a shipped Swift/Core ML app.
Run one model process at a time: concurrent inference would distort timings and
peak memory on the shared CPU/GPU. Input PNGs must already be oriented sRGB.

The default preprocessing reproduces the official ONNX example (bilinear RGB
in [0,1]). The official PyTorch API instead uses Lanczos + ImageNet mean/std.
Select --preprocessing explicitly when comparing these inconsistent pipelines;
neither the export nor that example establishes numerical parity by itself.
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
from pathlib import Path

import numpy as np
import onnxruntime as ort
import PIL
import psutil
from PIL import Image


REVISION = "e48a20765fb421d19dcdb0bf3cc61e802ca5ec8f"
MODEL_SHA256 = "22cea62108ff53b7ccc20f7a008bf30494228d84b1687f29ecbe76936a998101"
SIDE = 1024


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class MemorySampler:
    """Process RSS only; Core ML driver/GPU allocations may be absent."""

    def __init__(self) -> None:
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


def resize_bilinear(alpha: np.ndarray, width: int, height: int) -> np.ndarray:
    """Match bilinear align_corners=False with correct (height, width) order."""
    source_height, source_width = alpha.shape
    x = np.maximum((np.arange(width, dtype=np.float32) + 0.5) * (source_width / width) - 0.5, 0)
    y = np.maximum((np.arange(height, dtype=np.float32) + 0.5) * (source_height / height) - 0.5, 0)
    x0 = np.minimum(x.astype(np.int32), source_width - 1)
    y0 = np.minimum(y.astype(np.int32), source_height - 1)
    x1 = np.minimum(x0 + 1, source_width - 1)
    y1 = np.minimum(y0 + 1, source_height - 1)
    wx = x - x0
    wy = (y - y0)[:, None]
    horizontal = alpha[:, x0] * (1 - wx) + alpha[:, x1] * wx
    return (horizontal[y0] * (1 - wy) + horizontal[y1] * wy).astype(np.float32)


def preprocess(image: Image.Image, variant: str, dtype: type) -> np.ndarray:
    resampling = Image.Resampling.LANCZOS if variant == "pytorch" else Image.Resampling.BILINEAR
    resized = image.resize((SIDE, SIDE), resampling)
    array = np.asarray(resized, dtype=np.float32) / np.float32(255)
    tensor = array.transpose(2, 0, 1)[None]
    if variant == "pytorch":
        mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)[None, :, None, None]
        std = np.array([0.229, 0.224, 0.225], dtype=np.float32)[None, :, None, None]
        tensor = (tensor - mean) / std
    return np.ascontiguousarray(tensor, dtype=dtype)


def make_alpha(output: np.ndarray, size: tuple[int, int]) -> tuple[np.ndarray, dict]:
    if output.shape != (1, 1, SIDE, SIDE):
        raise ValueError(f"Unexpected BEN2 alpha shape: {output.shape}")
    alpha = output[0, 0].astype(np.float32)
    if not np.isfinite(alpha).all():
        raise ValueError("BEN2 returned non-finite alpha values")
    minimum, maximum = float(alpha.min()), float(alpha.max())
    if minimum < -0.0001 or maximum > 1.0001:
        raise ValueError(f"BEN2 output is outside the expected sigmoid range: {minimum}, {maximum}")
    alpha = resize_bilinear(alpha, *size)
    low, high = float(alpha.min()), float(alpha.max())
    if high - low <= 1e-8:
        raise ValueError("BEN2 returned a constant mask; refusing undefined min-max normalization")
    # Preserve the official ONNX example's min-max normalization and truncation.
    # Correct its width/height inversion when restoring non-square photographs.
    alpha = (alpha - low) / (high - low)
    gray8 = np.clip(alpha * 255, 0, 255).astype(np.uint8)
    return gray8, {
        "rawMinimum": minimum,
        "rawMaximum": maximum,
        "foregroundFractionAtHalf": float(np.mean(gray8 >= 128)),
        "fractionalAlphaFraction": float(np.mean((gray8 > 0) & (gray8 < 255))),
    }


def evaluate(args: argparse.Namespace, report: dict) -> None:
    inputs = sorted(args.input_dir.glob("*.png"))
    if not inputs:
        raise ValueError(f"No prepared PNG inputs in {args.input_dir}")
    if sha256(args.model) != MODEL_SHA256:
        raise ValueError("BEN2 model SHA-256 differs from the pinned official graph")
    available = ort.get_available_providers()
    if args.provider == "coreml" and "CoreMLExecutionProvider" not in available:
        raise RuntimeError("Requested CoreML provider is unavailable")
    options = ort.SessionOptions()
    options.intra_op_num_threads = args.threads
    options.inter_op_num_threads = 1
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.log_severity_level = 2
    options.enable_profiling = args.profile
    if args.profile:
        options.profile_file_prefix = str(args.output_dir / "ort-profile")
    providers = ["CPUExecutionProvider"]
    if args.provider == "coreml":
        providers.insert(0, ("CoreMLExecutionProvider", {
            "ModelFormat": "MLProgram",
            "MLComputeUnits": "CPUAndGPU",
            "RequireStaticInputShapes": "1",
        }))
    started = time.perf_counter()
    session = ort.InferenceSession(str(args.model), options, providers=providers)
    report["modelLoadSeconds"] = time.perf_counter() - started
    report["sessionProviders"] = session.get_providers()
    report["providerOptions"] = session.get_provider_options()
    model_inputs = session.get_inputs()
    if len(model_inputs) != 1 or model_inputs[0].shape != [1, 3, SIDE, SIDE]:
        raise ValueError(f"Unexpected BEN2 input contract: {[(i.name, i.shape) for i in model_inputs]}")
    input_meta = model_inputs[0]
    dtypes = {"tensor(float)": np.float32, "tensor(float16)": np.float16}
    if input_meta.type not in dtypes:
        raise ValueError(f"Unexpected BEN2 input dtype: {input_meta.type}")
    report["inputContract"] = {"name": input_meta.name, "shape": input_meta.shape, "type": input_meta.type}
    report["measurements"] = []
    for pass_index in range(args.repeats):
        for path in inputs:
            request_started = time.perf_counter()
            with Image.open(path) as source:
                image = source.convert("RGB")
            original_size = image.size
            tensor = preprocess(image, args.preprocessing, dtypes[input_meta.type])
            preprocess_ended = time.perf_counter()
            output = session.run(None, {input_meta.name: tensor})[0]
            inference_ended = time.perf_counter()
            gray8, diagnostics = make_alpha(output, original_size)
            validated_ended = time.perf_counter()
            target = args.output_dir / f"{path.stem}-alpha-pass{pass_index + 1}.png"
            Image.fromarray(gray8).save(target)
            raw_target = None
            if args.save_raw:
                raw_target = args.output_dir / f"{path.stem}-raw-native-pass{pass_index + 1}.npy"
                np.save(raw_target, output[0, 0].astype(np.float32))
                restored_raw = resize_bilinear(output[0, 0].astype(np.float32), *original_size)
                raw_gray8 = np.clip(restored_raw * 255, 0, 255).astype(np.uint8)
                Image.fromarray(raw_gray8).save(args.output_dir / f"{path.stem}-raw-alpha-pass{pass_index + 1}.png")
            saved_ended = time.perf_counter()
            measurement = {
                "image": path.name,
                "pass": pass_index + 1,
                "preprocessing": args.preprocessing,
                "firstPredictionInProcess": pass_index == 0 and path == inputs[0],
                "modelRetained": True,
                "width": original_size[0], "height": original_size[1],
                "preprocessSeconds": preprocess_ended - request_started,
                "inferenceSeconds": inference_ended - preprocess_ended,
                "postprocessSeconds": validated_ended - inference_ended,
                "requestSecondsExcludingLoadAndWrites": validated_ended - request_started,
                "outputWriteSeconds": saved_ended - validated_ended,
                "processRSSBytesAfterRequest": psutil.Process().memory_info().rss,
                "alphaPath": str(target), "alphaSHA256": sha256(target),
                **diagnostics,
            }
            if raw_target is not None:
                measurement["rawNativeAlphaPath"] = str(raw_target)
            report["measurements"].append(measurement)
            print(json.dumps(measurement), flush=True)
            write_report(args.output_dir, report)
    if args.profile:
        profile_path = session.end_profiling()
        report["ortProfilePath"] = profile_path
        events = json.loads(Path(profile_path).read_text())
        counts: dict[str, int] = {}
        for event in events:
            provider = event.get("args", {}).get("provider")
            if provider:
                counts[provider] = counts.get(provider, 0) + 1
        report["profileNodeEventCountsByProvider"] = counts
    report["medianInferenceSecondsAll"] = statistics.median(m["inferenceSeconds"] for m in report["measurements"])
    warm = [m["inferenceSeconds"] for m in report["measurements"] if m["pass"] > 1]
    if warm:
        report["medianInferenceSecondsRepeatedImages"] = statistics.median(warm)
    report["status"] = "complete"


def write_report(output_dir: Path, report: dict) -> None:
    temporary = output_dir / "results.json.tmp"
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(output_dir / "results.json")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--provider", choices=("coreml", "cpu"), default="coreml")
    parser.add_argument("--preprocessing", choices=("onnx-example", "pytorch"), default="onnx-example",
                        help="onnx-example: official ONNX bilinear RGB[0,1]; pytorch: official Lanczos + ImageNet normalization")
    parser.add_argument("--threads", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--profile", action="store_true", help="Record operator delegation; adds profiling overhead")
    parser.add_argument("--save-raw", action="store_true", help="Also save native Float32 alpha and restored raw Gray8 before min-max normalization")
    args = parser.parse_args()
    if args.threads < 1 or args.repeats < 1:
        parser.error("--threads and --repeats must be positive")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    ort.disable_telemetry_events()
    report = {
        "schemaVersion": 2,
        "model": "PramaLLC/BEN2 Base official ONNX",
        "revision": REVISION, "modelSHA256": MODEL_SHA256,
        "sourceURL": f"https://huggingface.co/PramaLLC/BEN2/blob/{REVISION}/BEN2_Base.onnx",
        "runtime": "Python harness / native ONNX Runtime C++",
        "onnxruntimeVersion": ort.__version__, "numpyVersion": np.__version__,
        "pillowVersion": PIL.__version__, "pythonVersion": sys.version,
        "platform": platform.platform(), "machine": platform.machine(),
        "requestedProvider": args.provider, "threads": args.threads,
        "preprocessing": args.preprocessing, "saveRawAlpha": args.save_raw,
        "availableProviders": ort.get_available_providers(), "profilingEnabled": args.profile,
        "inputSide": SIDE, "repeats": args.repeats,
        "status": "running",
        "limitations": [
            "Python harness overhead is included; this is not a native Swift app benchmark.",
            "Process RSS includes Python and runtime libraries; GPU/driver allocations may be absent.",
            "Model loading includes ORT setup and any Core ML compilation; system caches are not flushed.",
            "CoreML provider allows CPU fallback; configured providers do not prove full GPU delegation.",
            "Prepared oriented sRGB preview decode/resize is timed; RAW development is excluded.",
            "All predictions are serial to avoid shared-machine contention.",
            "Default onnx-example reproduces the official ONNX bilinear RGB[0,1] example; pytorch instead uses Lanczos + ImageNet normalization.",
            "The official ONNX example and PyTorch preprocessing disagree; variants must be identified separately and qualified.",
            "Output min-max normalization is retained; normalized values are not calibrated alpha coverage.",
            "Aspect restoration fixes the upstream ONNX example's swapped width/height interpolation.",
        ],
    }
    memory = MemorySampler()
    memory.start()
    started = time.perf_counter()
    exit_code = 0
    try:
        evaluate(args, report)
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        report["error"] = "KeyboardInterrupt: evaluation interrupted before completion"
        print(report["error"], file=sys.stderr, flush=True)
        exit_code = 130
    except Exception as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
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

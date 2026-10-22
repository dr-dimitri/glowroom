#!/usr/bin/env python3
"""Pinned large U²-Net skyseg ONNX evaluation on seven private local proxies.

Only ``download`` retrieves public weights. ``run`` remains offline. Model
processes run serially to avoid CPU/GPU and memory contention in the comparison.
The main masks threshold the raw sigmoid output at 0.5 before production-style
restoration. Raw soft values and the producer's per-image min-max visualization
are exported separately; no per-image stretch changes the main mask.
"""

from __future__ import annotations

import argparse
import json
import platform
import resource
import statistics
import sys
import time
import urllib.request
from pathlib import Path

# Shared helpers contain no model-specific inference or normalization policy.
from skywater import MemorySampler, restore_native_like_app, sha256, validate_inputs, write_report


REVISION = "3ba8c6df1d9ba9ff26f637c7ba9568ac11a9aa7f"
SOURCE_REVISION = "1f7811b32b64ddc957269defff84bc87a3f0b74f"
SOURCE_URL = f"https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing/blob/{SOURCE_REVISION}/onnx_interence.py"
MODEL = {"filename": "skyseg.onnx", "bytes": 175997079,
         "sha256": "ab9c34c64c3d821220a2886a4a06da4642ffa14d5b30e8d5339056a089aa1d39"}
MODEL_URL = f"https://huggingface.co/JianyuanWang/skyseg/resolve/{REVISION}/{MODEL['filename']}"
SIDE = 320


def verify_model(path: Path) -> dict:
    size, digest = path.stat().st_size, sha256(path)
    if size != MODEL["bytes"] or digest != MODEL["sha256"]:
        raise ValueError(f"Model differs from pinned large U²-Net graph (bytes={size}, SHA-256={digest})")
    return MODEL


def download_model(path: Path) -> None:
    if path.exists():
        verify_model(path)
        print(json.dumps({"status": "verified-existing", "model": str(path), **MODEL}))
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    # Exclusive creation and atomic publication preserve other local work.
    with temporary.open("xb") as destination:
        try:
            request = urllib.request.Request(MODEL_URL, headers={"User-Agent": "Glowroom-local-mask-evaluation/1"})
            with urllib.request.urlopen(request, timeout=120) as response:
                total = 0
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > MODEL["bytes"]:
                        raise ValueError("Download exceeds pinned model length")
                    destination.write(block)
            destination.flush()
            verify_model(temporary)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        path.hardlink_to(temporary)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps({"status": "downloaded-verified", "model": str(path), "url": MODEL_URL, **MODEL}))


def preprocess(rgb, np, cv2):
    resized = cv2.resize(rgb, (SIDE, SIDE), interpolation=cv2.INTER_LINEAR)
    # Match the official Python expression, including its float64 mean/std
    # intermediate before the final float32 cast. No division by image.max().
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float64)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float64)
    normalized = (resized.astype(np.float32) / 255 - mean) / std
    return np.ascontiguousarray(normalized.transpose(2, 0, 1)[None], dtype=np.float32)


def probability_masks(prediction, width: int, height: int, np):
    """Unstretched sigmoid plus explicit producer visualization, never re-sigmoid."""
    if prediction.shape != (1, 1, SIDE, SIDE) or not np.isfinite(prediction).all():
        raise ValueError(f"Expected finite [1,1,{SIDE},{SIDE}] sigmoid output; got {prediction.shape}")
    probability = prediction[0, 0].astype(np.float32)
    if probability.min() < -1e-6 or probability.max() > 1 + 1e-6:
        raise ValueError("Pinned graph's output is outside sigmoid range [0,1]")
    probability = np.clip(probability, 0, 1)
    native = (probability >= 0.5).astype(np.uint8) * 255
    # Both models now enter the same production restoration/refinement stages.
    restored = restore_native_like_app(native, width, height, np)
    binary = (restored >= 128).astype(np.uint8) * 255
    native_soft = np.floor(probability * 255 + 0.5).astype(np.uint8)
    soft = restore_native_like_app(native_soft, width, height, np)
    minimum, maximum = float(probability.min()), float(probability.max())
    # Official upstream code has a zero denominator for a constant result.
    # Preserve that fact as a diagnostic and export an empty mask in that case.
    official_defined = maximum > minimum
    official = ((probability - minimum) / (maximum - minimum) * 255).astype(np.uint8) if official_defined else np.zeros_like(native)
    official_restored = restore_native_like_app(official, width, height, np)
    return probability, native, restored, binary, soft, official, official_restored, official_defined


def evaluate(args, report: dict, np, cv2, ort, Image, psutil) -> None:
    verify_model(args.model)
    if args.provider == "coreml" and "CoreMLExecutionProvider" not in ort.get_available_providers():
        raise RuntimeError("Requested CoreML provider unavailable; choose --provider cpu explicitly")
    options = ort.SessionOptions()
    options.intra_op_num_threads, options.inter_op_num_threads = args.threads, 1
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
    report["stage"] = "modelLoad"
    write_report(args.output_dir, report)
    started = time.perf_counter()
    session = ort.InferenceSession(str(args.model), options, providers=providers)
    session.disable_fallback()
    report["modelLoadSeconds"] = time.perf_counter() - started
    report["sessionProviders"], report["providerOptions"] = session.get_providers(), session.get_provider_options()
    if args.provider == "coreml" and "CoreMLExecutionProvider" not in session.get_providers():
        raise RuntimeError("ORT silently created a CPU session after CoreML initialization failed")
    inputs, outputs = session.get_inputs(), session.get_outputs()
    if len(inputs) != 1 or inputs[0].name != "input.1" or inputs[0].shape != [1, 3, SIDE, SIDE] or inputs[0].type != "tensor(float)":
        raise ValueError(f"Unexpected pinned U²-Net input contract: {[(x.name, x.shape, x.type) for x in inputs]}")
    if [x.name for x in outputs] != [str(i) for i in range(1959, 1966)] or any(x.shape != [1, 1, SIDE, SIDE] or x.type != "tensor(float)" for x in outputs):
        raise ValueError(f"Unexpected pinned U²-Net output contract: {[(x.name, x.shape, x.type) for x in outputs]}")
    report["inputContract"] = {"name": inputs[0].name, "shape": inputs[0].shape, "type": inputs[0].type}
    report["outputContracts"] = [{"name": x.name, "shape": x.shape, "type": x.type} for x in outputs]
    report["selectedOutput"] = outputs[0].name
    report["stage"] = "inference"
    first_masks = {}
    process = psutil.Process()
    for pass_index in range(1, args.repeats + 1):
        for index, item in enumerate(report["inputs"]):
            path = args.input_dir / item["image"]
            report["activeImage"], report["activePass"] = path.name, pass_index
            request_started = time.perf_counter()
            with Image.open(path) as image:
                image.load()
                rgb, (width, height) = np.asarray(image, dtype=np.uint8), image.size
            read_ended = time.perf_counter()
            tensor = preprocess(rgb, np, cv2)
            if not np.isfinite(tensor).all():
                raise ValueError(f"Non-finite input tensor for {path.name}")
            preprocess_ended = time.perf_counter()
            prediction = session.run([outputs[0].name], {inputs[0].name: tensor})[0]
            inference_ended = time.perf_counter()
            probability, native, restored, binary, soft, official, official_restored, official_defined = probability_masks(prediction, width, height, np)
            diagnostics = {"sigmoidMinimum": float(probability.min()), "sigmoidMaximum": float(probability.max()),
                           "meanSkyProbability": float(probability.mean()), "skyFractionAtThreshold0_5": float((restored >= 128).mean()),
                           "officialMinMaxDefined": official_defined,
                           "officialMinMaxSkyFractionAtThreshold0_5": float((official_restored >= 128).mean())}
            postprocess_ended = time.perf_counter()
            prefix = f"{path.stem}-pass{pass_index}"
            masks = {"raw": restored, "native-raw": native, "binary": binary, "soft": soft}
            if args.save_official:
                masks.update({"official-minmax-native": official, "official-minmax": official_restored})
            paths = {}
            for suffix, pixels in masks.items():
                target = args.output_dir / f"{prefix}-{suffix}.png"
                Image.fromarray(pixels).save(target)
                paths[suffix] = str(target)
            if args.save_probability:
                np.save(args.output_dir / f"{prefix}-native-sky-probability.npy", probability)
            encode_ended = time.perf_counter()
            for suffix, pixels in masks.items():
                with Image.open(paths[suffix]) as decoded:
                    if decoded.mode != "L" or not np.array_equal(np.asarray(decoded), pixels):
                        raise ValueError(f"Mask failed lossless PNG round-trip: {paths[suffix]}")
            digest = sha256(Path(paths["raw"]))
            if pass_index == 1:
                first_masks[path.name] = digest
            measurement = {
                "image": path.name, "pass": pass_index, "width": width, "height": height,
                "firstPredictionInProcess": pass_index == 1 and index == 0, "modelRetained": True,
                "inputReadSeconds": read_ended - request_started, "preprocessSeconds": preprocess_ended - read_ended,
                "inferenceSeconds": inference_ended - preprocess_ended, "postprocessSeconds": postprocess_ended - inference_ended,
                "requestSecondsExcludingLoadAndWrites": postprocess_ended - request_started,
                "encodeAndWriteSeconds": encode_ended - postprocess_ended, "requestSecondsIncludingWrites": encode_ended - request_started,
                "outputVerificationSeconds": time.perf_counter() - encode_ended, "processRSSBytesAfterRequest": process.memory_info().rss,
                "rawPath": paths["raw"], "rawSHA256": digest, "nativeRawPath": paths["native-raw"],
                "nativeRawSHA256": sha256(Path(paths["native-raw"])), "outputPaths": paths,
                "identicalRawToFirstPass": digest == first_masks[path.name], **diagnostics,
            }
            report["measurements"].append(measurement)
            print(json.dumps(measurement, allow_nan=False), flush=True)
            write_report(args.output_dir, report)
    if args.profile:
        report["ortProfilePath"] = session.end_profiling()
        counts = {}
        for event in json.loads(Path(report["ortProfilePath"]).read_text()):
            provider = event.get("args", {}).get("provider")
            if provider:
                counts[provider] = counts.get(provider, 0) + 1
        report["profileNodeEventCountsByProvider"] = counts
        report["cpuNodeExecutionObserved"] = counts.get("CPUExecutionProvider", 0) > 0
        report["coreMLNodeExecutionObserved"] = counts.get("CoreMLExecutionProvider", 0) > 0
    else:
        report["cpuNodeExecutionObserved"] = True if args.provider == "cpu" else None
        report["coreMLNodeExecutionObserved"] = None
    repeated = [m for m in report["measurements"] if m["pass"] > 1]
    for key in ("inputReadSeconds", "preprocessSeconds", "inferenceSeconds", "postprocessSeconds", "encodeAndWriteSeconds", "requestSecondsExcludingLoadAndWrites"):
        report[f"median{key[0].upper() + key[1:]}RepeatedImages"] = statistics.median(m[key] for m in repeated)
    report["allRepeatedRawMasksIdentical"] = all(m["identicalRawToFirstPass"] for m in repeated)
    report.update({"stage": "complete", "status": "complete"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("download", "verify"):
        commands.add_parser(command).add_argument("--model", type=Path, required=True)
    runner = commands.add_parser("run", help="Offline serial benchmark on exactly seven prepared RGB PNG proxies")
    for option in ("model", "input-dir", "output-dir"):
        runner.add_argument(f"--{option}", type=Path, required=True)
    runner.add_argument("--provider", choices=("coreml", "cpu"), default="coreml")
    runner.add_argument("--compute-units", choices=("all", "cpu-gpu"), default="all")
    runner.add_argument("--threads", type=int, default=6)
    runner.add_argument("--repeats", type=int, default=2)
    runner.add_argument("--profile", action="store_true")
    runner.add_argument("--save-probability", action="store_true", help="Export native float32 sigmoid NPY, adding measured output cost")
    runner.add_argument("--save-official", action="store_true", help="Also export separately labelled producer per-image min-max visualization")
    args = parser.parse_args()
    if args.command == "download":
        download_model(args.model)
        return 0
    if args.command == "verify":
        print(json.dumps({"status": "verified", "revision": REVISION, **verify_model(args.model)}))
        return 0
    if args.threads < 1 or args.repeats < 2:
        parser.error("--threads must be positive; --repeats must be at least two complete passes")
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
        "schemaVersion": 1, "model": "JianyuanWang/skyseg large U²-Net", "revision": REVISION,
        "modelURL": MODEL_URL, "modelBytes": MODEL["bytes"], "modelSHA256": MODEL["sha256"],
        "sourceRevision": SOURCE_REVISION, "sourceURL": SOURCE_URL,
        "runtime": "Python harness / native ONNX Runtime C++", "pythonVersion": sys.version,
        "onnxruntimeVersion": ort.__version__, "numpyVersion": np.__version__, "opencvVersion": cv2.__version__,
        "pillowVersion": PIL.__version__, "psutilVersion": psutil.__version__, "platform": platform.platform(),
        "machine": platform.machine(), "inputs": manifest, "inputSide": SIDE,
        "requestedProvider": args.provider, "requestedCoreMLComputeUnits": args.compute_units,
        "availableProviders": ort.get_available_providers(), "threads": args.threads, "repeats": args.repeats,
        "profilingEnabled": args.profile, "saveNativeProbability": args.save_probability,
        "saveOfficialMinMax": args.save_official,
        "preprocessing": "RGB uint8; OpenCV INTER_LINEAR stretch to 320x320; float32 /255 then float64 ImageNet mean/std intermediate; NCHW float32; no image-maximum scaling",
        "rawMaskPostprocessing": "First graph output is already sigmoid, high=sky; native sigmoid >=0.5 binary sky mask; production Swift half-pixel Double bilinear restoration; no additional sigmoid or per-image min-max",
        "binaryMaskPostprocessing": "Restored hard-label Gray8 >=128; diagnostic only, raw.png retains interpolated edge coverage for shared app refiner",
        "softMaskPostprocessing": "Unstretched native sigmoid quantized to Gray8 rounded ties up then production half-pixel Double bilinear restoration; exploratory, not calibrated alpha",
        "officialAlternative": "First sigmoid output per-image min-max, native uint8 truncation, production restoration; constant output guarded to empty instead of producer division by zero",
        "cpuFallback": "CPU graph partitions allowed with CoreML; no silent runtime retry; profile required to establish actual provider use",
        "measurements": [], "status": "running", "stage": "preflightComplete",
        "limitations": [
            "Developer Python/ORT harness, not a native Swift app benchmark; different process overhead than Apple DETR.",
            "Model processes and image inference are serial to avoid benchmark contention; ORT CPU kernels use bounded parallel threads.",
            "Model retained across full passes, no discarded warmup; system/driver caches not flushed.",
            "CoreML ALL permits CPU/GPU/ANE; provider configuration or profile does not establish a hardware-unit split.",
            "Profile and optional exports add measured work; graph optimization may remove unused U²-Net side outputs.",
            "Input preflight decodes proxies, warming filesystem caches; original JPEG/RAW development excluded.",
            "Process RSS includes Python/runtime and may exclude GPU/driver allocations.",
            "Sigmoid values are not proven calibrated compositing alpha; 0.5 is a fixed unoptimized native comparison threshold.",
            "Postprocessing timing includes unstretched masks, binary threshold and separately labelled producer min-max alternative.",
            "The upstream demonstration pyrDown loop is omitted because proxies are already standardized; per-model image reduction would change the comparison input.",
        ],
    }
    sampler = MemorySampler(psutil)
    sampler.start()
    started, exit_code = time.perf_counter(), 0
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
        sampler.stop()
        report["totalProcessWorkSeconds"], report["sampledPeakProcessRSSBytes"] = time.perf_counter() - started, sampler.peak
        high_water = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        report["peakProcessRSSBytes"] = high_water if sys.platform == "darwin" else high_water * 1024
        write_report(args.output_dir, report)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

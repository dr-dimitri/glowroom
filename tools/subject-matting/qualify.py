#!/usr/bin/env python3
"""Compare a local image's native Core ML alpha against pinned PyTorch.

The input image remains local. Output contains masks, metrics and explicit
model/source hashes; it does not infer a ground-truth accuracy score.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image
import torch

from prepare import FILES, REVISION, SIZE, digest, load_model, sources
from validation import compare, validate_array


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference-only", action="store_true", help="Save reference then exit before native compilation to bound peak memory")
    parser.add_argument("--side", type=int, choices=(1024, 2048), default=SIZE)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Refusing to overwrite qualification output")
    sources(args.source, download=False)
    image = Image.open(args.image).convert("RGB")
    side = args.side
    square = image.resize((side, side), Image.Resampling.BILINEAR)
    if args.reference_only:
        args.output.mkdir(parents=True)
        tensor = torch.from_numpy(np.array(square).astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
        torch.set_num_threads(min(8, os.cpu_count() or 1))
        start = time.monotonic()
        print("Loading reference and predicting on CPU…", flush=True)
        model = load_model(args.source)
        with torch.inference_mode():
            reference = model(tensor).numpy()
        reference_seconds = time.monotonic() - start
        validate_array(reference, shape=(1, 1, side, side), coverage=True)
        np.save(args.output / "reference-alpha.npy", reference)
        square.save(args.output / "reference-input.png")
        report = {"referenceLoadAndInferenceSeconds": reference_seconds,
                  "processPeakResidentBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                  "imageSHA256": digest(args.image), "revision": REVISION,
                  "weightsSHA256": FILES["model.safetensors"]}
        (args.output / "reference.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
        return
    # A subprocess makes the CPU allocator release the full reference model
    # before native compilation/inference. Keeping both pools in one process
    # exceeded the available memory in the qualification environment.
    subprocess.run([sys.executable, str(Path(__file__).resolve()), "--source", str(args.source),
                    "--model", str(args.model), "--image", str(args.image), "--output", str(args.output),
                    "--reference-only", "--side", str(side)], check=True)
    reference = np.load(args.output / "reference-alpha.npy")
    reference_report = json.loads((args.output / "reference.json").read_text())
    reference_seconds = reference_report["referenceLoadAndInferenceSeconds"]
    print(f"Reference completed in {reference_seconds:.2f}s; loading native model…", flush=True)
    start = time.monotonic()
    native = ct.models.MLModel(str(args.model), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    load_seconds = time.monotonic() - start
    print(f"Native load completed in {load_seconds:.2f}s", flush=True)
    native_seconds = []
    comparisons = []
    result = None
    for _ in range(2):
        start = time.monotonic()
        result = native.predict({"image": square})["alpha"]
        native_seconds.append(time.monotonic() - start)
        print(f"Native prediction completed in {native_seconds[-1]:.2f}s", flush=True)
        # Production loads a fresh model, so the first prediction must satisfy
        # the same reference gate as the warmed prediction.
        comparisons.append(compare(reference, result, shape=(1, 1, side, side), coverage=True,
                                   mean_limit=0.01, p99_limit=0.1))
        np.save(args.output / f"native-alpha-{len(comparisons)}.npy", result)
    error = np.abs(reference - result)
    np.save(args.output / "reference-alpha.npy", reference)
    np.save(args.output / "native-alpha.npy", result)
    for name, alpha in (("reference", reference), ("native", result)):
        matte = Image.fromarray(np.round(alpha[0, 0] * 255).astype(np.uint8), "L").resize(image.size, Image.Resampling.BILINEAR)
        matte.save(args.output / f"{name}-mask.png")
        # Diagnostic -5EV background exposure in linear sRGB. Retain the full
        # fractional alpha when mixing original and adjusted linear pixels.
        rgb = np.array(image).astype(np.float32) / 255
        linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
        coverage = np.asarray(Image.fromarray(alpha[0, 0], "F").resize(image.size, Image.Resampling.BILINEAR))[:, :, None]
        linear *= coverage + (1 - coverage) / 32
        rgb = np.where(linear <= 0.0031308, linear * 12.92, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - 0.055)
        Image.fromarray(np.round(np.clip(rgb, 0, 1) * 255).astype(np.uint8), "RGB").save(args.output / f"{name}-background-minus5ev.png")
    report = {
        "revision": REVISION, "weightsSHA256": FILES["model.safetensors"],
        "imageSHA256": digest(args.image), "imageSize": list(image.size),
        "referenceLoadAndInferenceSeconds": reference_seconds,
        "nativeLoadSeconds": load_seconds, "nativeInferenceSeconds": native_seconds,
        "nativeProcessPeakResidentBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "referenceProcessPeakResidentBytes": reference_report["processPeakResidentBytes"],
        "alphaMinimum": float(result.min()), "alphaMaximum": float(result.max()),
        "meanAbsoluteError": float(error.mean()), "maximumAbsoluteError": float(error.max()),
        "p99AbsoluteError": float(np.percentile(error, 99)),
        "perPredictionComparisons": comparisons,
        "limitations": "Single image, no ground-truth mask; reference and native run in separate processes; native process also imports Python conversion libraries and includes compiler runtime. GPU/driver memory not fully represented."
    }
    (args.output / "qualification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Offline Float32 CPU reference for two BEN2 photographs, not an app runtime.

Audited official source and safetensors are pinned independently. Never use the
source's pickle loader, network model loader, video helpers, or PIL inference
wrapper. The latter swaps width/height while restoring the aspect ratio.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import resource
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import numpy as np
import PIL
from PIL import Image
import torch
from safetensors.torch import load_file


REVISION = "e48a20765fb421d19dcdb0bf3cc61e802ca5ec8f"
SOURCE_SHA256 = "16e6132faefc112ea97072b93df40c847a33aad7c04a2e578b417e9ebb6094a7"
WEIGHTS_SHA256 = "ea8b7907176a09667c86343dc7d00de6a6d871076cb90bb5f753618fd6fb3ebb"


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def save_json(path: Path, report: dict) -> None:
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(path)


def comparison_provenance(directory: Path | None) -> dict:
    if directory is None:
        return {"compareDir": None, "comparePreprocessing": None}
    directory = directory.resolve()
    report_path = directory / "results.json"
    compared_report = json.loads(report_path.read_text()) if report_path.is_file() else {}
    return {
        "compareDir": str(directory),
        "comparePreprocessing": compared_report.get("preprocessing", "unspecified in compared report"),
        "compareResultsPath": str(report_path) if report_path.is_file() else None,
        "compareResultsSHA256": digest(report_path) if report_path.is_file() else None,
        "compareModelSHA256": compared_report.get("modelSHA256"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--input-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--images", default="1,6")
    parser.add_argument("--threads", type=int, default=6)
    parser.add_argument("--preprocessing", choices=("pytorch", "onnx-example"), default="pytorch")
    parser.add_argument("--compare-dir", type=Path, help="Existing ONNX Gray8 outputs; no ONNX execution")
    args = parser.parse_args()
    indices = [int(value) for value in args.images.split(",")]
    if args.threads < 1 or not indices or any(index not in range(1, 8) for index in indices):
        parser.error("Expected positive threads and image indices from 1 through 7")
    comparison = comparison_provenance(args.compare_dir)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    source_path, weights_path = args.source_dir / "BEN2.py", args.source_dir / "model.safetensors"
    if digest(source_path) != SOURCE_SHA256 or digest(weights_path) != WEIGHTS_SHA256:
        raise ValueError("Official BEN2 reference source or safetensors checksum mismatch")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    started = time.perf_counter()
    spec = importlib.util.spec_from_file_location("audited_offline_ben2_reference", source_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    model = module.BEN_Base().cpu().float().eval()
    # Safetensors only: load all names strictly, never deserialize a pickle.
    state = load_file(str(weights_path), device="cpu")
    model.load_state_dict(state, strict=True)
    del state
    load_seconds = time.perf_counter() - started
    report = {
        "model": "PramaLLC/BEN2 Base Float32 PyTorch reference",
        "revision": REVISION, "sourceSHA256": SOURCE_SHA256, "weightsSHA256": WEIGHTS_SHA256,
        "sourceURL": f"https://huggingface.co/PramaLLC/BEN2/blob/{REVISION}/BEN2.py",
        "weightsURL": f"https://huggingface.co/PramaLLC/BEN2/blob/{REVISION}/model.safetensors",
        "device": "cpu", "precision": "Float32", "torchVersion": torch.__version__,
        "numpyVersion": np.__version__, "pillowVersion": PIL.__version__,
        "platform": platform.platform(), "threads": args.threads,
        "modelLoadSeconds": load_seconds, "preprocessing": args.preprocessing,
        **comparison,
        "records": [],
        "limitations": [
            "Developer Python reference, not shipped Swift performance.",
            "Official PyTorch uses Lanczos + ImageNet normalization; official ONNX example uses bilinear RGB[0,1].",
            "Choose onnx-example for matched input numerical comparison; pytorch measures official reference behavior.",
            "Aspect restoration uses correct height,width order and preserves raw alpha before min-max normalization.",
            "Gray8 comparison to ONNX includes interpolation, normalization, quantization and graph differences.",
            "No ground truth is available; numerical agreement does not establish segmentation accuracy.",
            "Predictions are serial to keep shared CPU and memory measurements uncontended.",
        ],
    }
    print(json.dumps({"modelLoadSeconds": load_seconds, "preprocessing": args.preprocessing}), flush=True)
    for index in indices:
        identity = f"test_picture{index}"
        path = args.input_dir / f"{identity}.png"
        request_started = time.perf_counter()
        with Image.open(path) as opened:
            image = opened.convert("RGB")
        resample = Image.Resampling.LANCZOS if args.preprocessing == "pytorch" else Image.Resampling.BILINEAR
        image_input = image.resize((1024, 1024), resample)
        array = np.asarray(image_input, dtype=np.float32) / np.float32(255)
        tensor = torch.from_numpy(array.transpose(2, 0, 1).copy())[None]
        if args.preprocessing == "pytorch":
            mean = torch.tensor([0.485, 0.456, 0.406])[None, :, None, None]
            std = torch.tensor([0.229, 0.224, 0.225])[None, :, None, None]
            tensor = (tensor - mean) / std
        input_ended = time.perf_counter()
        with torch.inference_mode():
            alpha = model(tensor)
        inference_ended = time.perf_counter()
        if alpha.shape != (1, 1, 1024, 1024) or not torch.isfinite(alpha).all():
            raise ValueError("Invalid reference alpha shape or values")
        if float(alpha.min()) < 0 or float(alpha.max()) > 1:
            raise ValueError("Reference output is outside sigmoid range")
        native = alpha[0, 0].numpy()
        restored = torch.nn.functional.interpolate(alpha, size=(image.height, image.width), mode="bilinear", align_corners=False)[0, 0].numpy()
        low, high = float(restored.min()), float(restored.max())
        if high - low <= 1e-8:
            raise ValueError("Constant reference mask cannot be min-max normalized")
        normalized = (restored - low) / (high - low)
        gray8 = np.clip(normalized * 255, 0, 255).astype(np.uint8)
        validated_ended = time.perf_counter()
        np.save(args.output_dir / f"{identity}-raw-native.npy", native)
        np.save(args.output_dir / f"{identity}-model-input.npy", tensor.numpy())
        np.save(args.output_dir / f"{identity}-raw-restored.npy", restored)
        Image.fromarray(np.clip(restored * 255, 0, 255).astype(np.uint8)).save(args.output_dir / f"{identity}-raw-alpha.png")
        Image.fromarray(gray8).save(args.output_dir / f"{identity}-normalized-alpha.png")
        record = {
            "image": path.name, "preprocessSeconds": input_ended - request_started,
            "inferenceSeconds": inference_ended - input_ended,
            "postprocessSeconds": validated_ended - inference_ended,
            "rawMinimum": float(native.min()), "rawMaximum": float(native.max()),
            "width": image.width, "height": image.height,
        }
        if args.compare_dir:
            candidate = args.compare_dir / f"{identity}-alpha-pass1.png"
            with Image.open(candidate) as opened:
                candidate_alpha = np.asarray(opened.convert("L"), dtype=np.float32) / np.float32(255)
            if candidate_alpha.shape != restored.shape:
                raise ValueError("ONNX/reference aspect mismatch")
            delta = np.abs(candidate_alpha - gray8.astype(np.float32) / np.float32(255))
            record["normalizedGray8DifferenceToONNX"] = {
                "mean": float(delta.mean()), "p99": float(np.quantile(delta, 0.99)), "maximum": float(delta.max()),
                "candidatePath": str(candidate.resolve()), "candidateSHA256": digest(candidate)}
        report["records"].append(record)
        report["processPeakResidentBytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        save_json(args.output_dir / "results.json", report)
        print(json.dumps(record), flush=True)
    report["status"] = "complete"
    save_json(args.output_dir / "results.json", report)


if __name__ == "__main__":
    main()

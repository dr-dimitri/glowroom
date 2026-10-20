#!/usr/bin/env python3
"""Offline text-guided EfficientSAM3 EV-M evaluation, without app integration.

Use an isolated environment and a pinned upstream checkout. No model inference
is run at import time. All photographs stay local; Hugging Face access is disabled
before model construction. Evaluate one model process at a time to avoid
distorting latency and memory measurements. Upstream output probabilities are
segmentation confidence, not calibrated fractional alpha for matting.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time

CODE_REVISION = "bd0936c788fed8d51fa799437f05abd97b401b06"
WEIGHT_REVISION = "85b05896928f974e308f889d7ccb2eefc069de98"
WEIGHT_SHA256 = "086b04b2e7da7cc98aa4621b70c7291608aa9d187357b98d03bd4d6533ed5a17"


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def evaluate(args: argparse.Namespace) -> None:
    revision = subprocess.check_output(
        ["git", "-C", str(args.repo), "rev-parse", "HEAD"], text=True).strip()
    if revision != CODE_REVISION:
        raise ValueError(f"Unexpected upstream code revision: {revision}")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    sys.path.insert(0, str(args.repo.resolve()))
    import numpy as np
    from PIL import Image
    import torch
    builder = importlib.import_module("sam3.model_builder")
    from sam3.model.sam3_image_processor import Sam3Processor
    # Upstream precomputes positional caches using its globally preferred device,
    # even when the builder explicitly receives CPU. Pin that helper for this
    # process so the CPU test never mixes cached MPS tensors into CPU execution.
    device_helpers = importlib.import_module("sam3.device")
    device_helpers.get_device = lambda: torch.device(args.device)

    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    manifest = json.loads(args.manifest.read_text())
    images = manifest["images"]
    if args.limit:
        images = images[:args.limit]
    if not images:
        raise ValueError("No images in manifest")
    if args.output.exists():
        raise ValueError("Refusing to overwrite existing output directory")
    args.output.mkdir(parents=True)
    checkpoint_sha = digest(args.checkpoint)
    if checkpoint_sha != WEIGHT_SHA256:
        raise ValueError("Checkpoint checksum differs from pinned EV-M weights")
    # The upstream loader filters missing keys and uses strict=False. Refuse a
    # partially initialized model rather than silently benchmark random weights.
    checkpoint_audit = {}

    def load_checked(model, checkpoint_path):
        weights = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
        weights = weights.get("model", weights)
        clean = {key.removeprefix("detector.").replace("student_trunk.", ""): value
                 for key, value in weights.items()}
        missing, unexpected = model.load_state_dict(clean, strict=False)
        checkpoint_audit.update(missingKeys=missing, unexpectedKeys=unexpected)
        if missing:
            raise ValueError(f"Checkpoint leaves {len(missing)} model tensors uninitialized: {missing[:10]}")

    builder._load_checkpoint = load_checked
    started = time.perf_counter()
    model = builder.build_efficientsam3_image_model(
        checkpoint_path=str(args.checkpoint), backbone_type="efficientvit", model_name="b1",
        text_encoder_type="MobileCLIP-S0", text_encoder_context_length=16,
        load_from_HF=False, device="cpu", compile=False, enable_inst_interactivity=False,
    )
    model.eval().to(args.device)
    load_seconds = time.perf_counter() - started
    parameters = sum(value.numel() for value in model.parameters())
    if parameters > 120_000_000:
        raise ValueError(f"EV-M unexpectedly contains {parameters} parameters")
    processor = Sam3Processor(model, device=args.device, resolution=1008,
                              confidence_threshold=args.confidence)

    def synchronize():
        if args.device == "mps":
            torch.mps.synchronize()

    report = {
        "model": "EfficientSAM3 EV-M Stage 3", "codeRevision": CODE_REVISION,
        "weightRevision": WEIGHT_REVISION, "weightSHA256": checkpoint_sha,
        "parameters": parameters, "checkpointAudit": checkpoint_audit,
        "python": platform.python_version(), "torch": torch.__version__,
        "device": args.device, "threads": args.threads, "inputSide": 1008,
        "confidenceThreshold": args.confidence, "loadSeconds": load_seconds,
        "maskSemantics": "union of all binary target-instance segmentations; probability files are diagnostic confidence, not matting alpha",
        "records": [],
    }
    report_path = args.output / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    with torch.inference_mode():
        for index, item in enumerate(images):
            for iteration in range(1, 3 if index == 0 else 2):
                started = time.perf_counter()
                image = Image.open(item["path"]).convert("RGB")
                input_seconds = time.perf_counter() - started
                synchronize()
                stage = time.perf_counter()
                state = processor.set_image(image)
                synchronize()
                encoder_seconds = time.perf_counter() - stage
                stage = time.perf_counter()
                state = processor.set_text_prompt(item["target"], state)
                synchronize()
                prompt_seconds = time.perf_counter() - stage
                masks = state["masks"].detach().cpu().numpy()
                probabilities = state["masks_logits"].detach().cpu().numpy()
                scores = state["scores"].detach().cpu().tolist()
                if not np.isfinite(probabilities).all() or not np.isfinite(scores).all():
                    raise ValueError("Non-finite segmentation output")
                if len(masks):
                    union = np.any(masks[:, 0], axis=0)
                    probability = probabilities[:, 0].max(axis=0)
                else:
                    union = np.zeros((image.height, image.width), dtype=bool)
                    probability = np.zeros_like(union, dtype=np.float32)
                if union.shape != (image.height, image.width):
                    raise ValueError(f"Unexpected mask extent: {union.shape}")
                request_seconds = time.perf_counter() - started
                output_started = time.perf_counter()
                stem = f"{item['id']}-{iteration}"
                Image.fromarray(union.astype(np.uint8) * 255, "L").save(args.output / f"{stem}-alpha.png")
                Image.fromarray(np.rint(np.clip(probability, 0, 1) * 255).astype(np.uint8), "L").save(
                    args.output / f"{stem}-probability.png")
                record = {
                    "id": item["id"], "target": item["target"], "iteration": iteration,
                    "inputSeconds": input_seconds, "encoderSeconds": encoder_seconds,
                    "promptSeconds": prompt_seconds, "pipelineSeconds": encoder_seconds + prompt_seconds,
                    "requestSeconds": request_seconds, "outputSeconds": time.perf_counter() - output_started,
                    "instances": len(masks), "scores": scores,
                    "foregroundFractionAtHalf": float(union.mean()),
                }
                report["records"].append(record)
                rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                report["peakRSSBytes"] = rss if sys.platform == "darwin" else rss * 1024
                if args.device == "mps":
                    report["mpsDriverAllocatedBytesAtLastSample"] = torch.mps.driver_allocated_memory()
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(record), flush=True)
                del state, masks, probabilities


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--threads", type=int, choices=range(1, 9), default=4)
    parser.add_argument("--confidence", type=float, default=0.5)
    parser.add_argument("--limit", type=int)
    evaluate(parser.parse_args())

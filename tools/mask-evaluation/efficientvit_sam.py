#!/usr/bin/env python3
"""Pinned official EfficientViT-SAM-L1 evaluation; no Glowroom app integration."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import sys
import tarfile
import time

MODEL_REPOSITORY = "mit-han-lab/efficientvit-sam"
MODEL_REVISION = "a2f0c5929196a13ef1ffc9338d3f9e482e1e0e68"
MODEL_FILENAME = "efficientvit_sam_l1.pt"
MODEL_BYTES = 190916834
MODEL_SHA256 = "fa151df2b9b96896accd505470755cdd293a4c50cdabac95478f3fbd86d9152b"
EFFICIENTVIT_REVISION = "e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace"
SAM_REVISION = "dca509fe793f601edb92606367a655c15ac00fdf"
SOURCE_ARCHIVES = (
    ("efficientvit", "efficientvit", EFFICIENTVIT_REVISION,
     "0e45211a243cb342a2156f7da0d3b1e07f98dbd9c6761f1b40fda313a3a76636"),
    ("segment-anything", "segment_anything", SAM_REVISION,
     "b693c2358e9e1c63589a322b1baa6a6dc384df0013ff455d933d9a8e23549dab"),
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def verify_model(path):
    if path.stat().st_size != MODEL_BYTES or sha256(path) != MODEL_SHA256:
        raise ValueError("Official EfficientViT-SAM-L1 checkpoint integrity mismatch")


def verify_sources(root):
    """Verify every imported-package Python source against the pinned archive."""
    records = []
    for directory, package, revision, expected_archive_hash in SOURCE_ARCHIVES:
        archive_path = root / "sources" / f"{directory}.tar.gz"
        if sha256(archive_path) != expected_archive_hash:
            raise ValueError(f"Source archive integrity mismatch: {directory}")
        expected = {}
        with tarfile.open(archive_path) as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts[1:]
                if member.isfile() and parts and parts[0] == package and member.name.endswith(".py"):
                    stream = archive.extractfile(member)
                    expected[str(Path(*parts))] = hashlib.sha256(stream.read()).hexdigest()
        source_root = root / "sources" / directory
        actual = {str(path.relative_to(source_root)): sha256(path)
                  for path in (source_root / package).rglob("*.py")}
        if not expected or expected != actual:
            raise ValueError(f"Extracted source differs from pinned archive: {directory}")
        records.append({"directory": directory, "revision": revision,
            "archiveSHA256": expected_archive_hash, "verifiedPythonFiles": len(actual),
            "packagePythonTreeSHA256": hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest()})
    return records


def download(root):
    from huggingface_hub import hf_hub_download

    root.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    path = Path(hf_hub_download(repo_id=MODEL_REPOSITORY, filename=MODEL_FILENAME,
        revision=MODEL_REVISION, local_dir=root / "models", cache_dir=root / "hf-cache", token=False))
    verify_model(path)
    provenance = {"repository": MODEL_REPOSITORY, "revision": MODEL_REVISION,
        "filename": MODEL_FILENAME, "bytes": MODEL_BYTES, "sha256": MODEL_SHA256,
        "license": "Apache-2.0", "huggingfaceHubVersion": importlib.metadata.version("huggingface_hub"),
        "downloadAndVerificationSeconds": time.perf_counter() - started}
    write_json(root / "model-provenance.json", provenance)
    print(json.dumps(provenance), flush=True)


def versions():
    packages = ["torch", "torchvision", "huggingface_hub", "numpy", "pillow", "omegaconf",
                "timm", "einops", "opencv-python-headless", "scipy", "torchprofile"]
    return {name: importlib.metadata.version(name) for name in packages}


def run(args):
    started = time.perf_counter()
    root = args.root.resolve()
    if args.device == "mps" and os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK") != "0":
        raise ValueError("MPS evaluation requires PYTORCH_ENABLE_MPS_FALLBACK=0 before importing torch")
    source_verification = verify_sources(root)
    sys.path.insert(0, str(root / "sources" / "segment-anything"))
    sys.path.insert(0, str(root / "sources" / "efficientvit"))
    import numpy as np
    import torch
    from PIL import Image
    from efficientvit.models.efficientvit.sam import EfficientViTSamPredictor
    from efficientvit.sam_model_zoo import create_sam_model

    import_seconds = time.perf_counter() - started
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    if args.device == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("MPS is not available; use an explicitly labelled CPU run")
    device = torch.device(args.device)

    def synchronize():
        if args.device == "mps":
            torch.mps.synchronize()

    def memory():
        value = {"processPeakResidentBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
        if args.device == "mps":
            value["mpsCurrentAllocatedBytes"] = torch.mps.current_allocated_memory()
            value["mpsDriverAllocatedBytes"] = torch.mps.driver_allocated_memory()
        return value

    manifest = json.loads(args.manifest.read_text())
    images = manifest["images"]
    if args.only:
        images = [item for item in images if item["id"] == args.only]
    if not images:
        raise ValueError("No images selected")
    for item in images:
        for value in [item["id"], *(prompt["id"] for prompt in item["prompts"])]:
            if not value or not all(c.isascii() and (c.isalnum() or c in "-_") for c in value):
                raise ValueError("Unsafe output identifier")
    iterations = manifest.get("iterations", 2)
    if not 1 <= iterations <= 3:
        raise ValueError("Expected one to three prompt iterations")
    model_path = root / "models" / MODEL_FILENAME
    verify_model(model_path)
    args.output.mkdir(parents=True, exist_ok=False)
    model_start = time.perf_counter()
    model = create_sam_model("l1", pretrained=False)
    checkpoint = torch.load(model_path, map_location="cpu", weights_only=True)
    state_dict = checkpoint.get("state_dict", checkpoint)
    model.load_state_dict(state_dict, strict=True)
    del state_dict, checkpoint
    model.eval()
    build_load_cpu_seconds = time.perf_counter() - model_start
    transfer_start = time.perf_counter()
    model.to(device=device, dtype=torch.float32)
    synchronize()
    transfer_seconds = time.perf_counter() - transfer_start
    assert tuple(model.image_size) == (1024, 512), model.image_size
    assert tuple(model.prompt_encoder.input_image_size) == (1024, 1024)
    predictor = EfficientViTSamPredictor(model)

    class PhaseTimers:
        def __init__(self):
            self.calls = {name: [] for name in ["image_encoder", "prompt_encoder", "mask_decoder"]}
            self.beginnings = {}
            self.encoder_shapes = []
            self.handles = []
            for name in self.calls:
                self.handles.append(getattr(model, name).register_forward_pre_hook(self.before(name)))
                self.handles.append(getattr(model, name).register_forward_hook(self.after(name)))

        def before(self, name):
            def hook(module, inputs):
                synchronize()
                if name == "image_encoder":
                    shape = list(inputs[0].shape)
                    assert shape == [1, 3, 512, 512], shape
                    self.encoder_shapes.append(shape)
                self.beginnings[name] = time.perf_counter()
            return hook

        def after(self, name):
            def hook(module, inputs, output):
                synchronize()
                self.calls[name].append(time.perf_counter() - self.beginnings[name])
            return hook

    phases = PhaseTimers()
    reports, memory_samples = [], [memory()]
    first_request_start = time.perf_counter()
    with torch.inference_mode():
        for image_index, item in enumerate(images):
            image_start = time.perf_counter()
            decode_start = time.perf_counter()
            with Image.open(item["path"]) as source:
                image = np.asarray(source.convert("RGB"))
            decode_seconds = time.perf_counter() - decode_start
            set_start = time.perf_counter()
            predictor.set_image(image)
            synchronize()
            set_seconds = time.perf_counter() - set_start
            original_h, original_w = image.shape[:2]
            expected_scale = 1024 / max(original_h, original_w)
            expected_prompt_shape = (int(original_h * expected_scale + .5), int(original_w * expected_scale + .5))
            assert predictor.input_size == expected_prompt_shape
            assert predictor.original_size == (original_h, original_w)
            encoder_kernel_seconds = phases.calls["image_encoder"][-1]
            repeat_encoder = None
            if image_index == 0 and args.repeat_encoder_first:
                original_features = predictor.features.detach().clone()
                synchronize()
                repeat_start = time.perf_counter()
                predictor.set_image(image)
                synchronize()
                repeat_seconds = time.perf_counter() - repeat_start
                delta = float((predictor.features - original_features).abs().max().cpu().item())
                repeat_encoder = {"setImageSeconds": repeat_seconds,
                    "encoderKernelSeconds": phases.calls["image_encoder"][-1], "maximumFeatureDifference": delta}
                del original_features
            image_directory = args.output / item["id"]
            image_directory.mkdir()
            prompt_reports = []
            for prompt in item["prompts"]:
                box = np.asarray(prompt["box"], dtype=np.float32) if prompt.get("box") else None
                if box is not None:
                    if box.shape != (4,) or not np.isfinite(box).all() or (box < 0).any() or (box > 1).any() or box[0] >= box[2] or box[1] >= box[3]:
                        raise ValueError("Invalid normalized box")
                    box = box * np.asarray([original_w, original_h, original_w, original_h], dtype=np.float32)
                point_values = prompt.get("points", [])
                points = np.asarray([[p["x"] * original_w, p["y"] * original_h] for p in point_values], dtype=np.float32) if point_values else None
                labels = np.asarray([p["label"] for p in point_values], dtype=np.int32) if point_values else None
                if points is not None and (not np.isfinite(points).all() or (points < 0).any() or (points > [original_w, original_h]).any() or not np.isin(labels, [0, 1]).all()):
                    raise ValueError("Invalid normalized points")
                predictions, selected_masks, selected_logits, scores_by_repeat, selections = [], [], [], [], []
                first_prompt_start = time.perf_counter()
                for iteration in range(iterations):
                    synchronize()
                    predict_start = time.perf_counter()
                    # Use the unmodified official NumPy predictor. It applies the
                    # 1024 prompt geometry, restores source dimensions and copies
                    # MPS outputs to CPU. These costs belong to predictSeconds.
                    masks, scores, low_res_logits = predictor.predict(point_coords=points,
                        point_labels=labels, box=box, multimask_output=True, return_logits=True)
                    synchronize()
                    predict_seconds = time.perf_counter() - predict_start
                    if not np.isfinite(masks).all() or not np.isfinite(scores).all() or not np.isfinite(low_res_logits).all():
                        raise ValueError("Nonfinite prediction")
                    selected = int(np.argmax(scores))
                    selected_masks.append(np.asarray(masks[selected] > model.mask_threshold))
                    selected_logits.append(np.asarray(low_res_logits[selected], dtype=np.float32).copy())
                    scores_by_repeat.append(scores.tolist())
                    selections.append(selected)
                    predictions.append({"predictSeconds": predict_seconds,
                        "promptEncoderKernelSeconds": phases.calls["prompt_encoder"][-1],
                        "maskDecoderKernelSeconds": phases.calls["mask_decoder"][-1]})
                    if iteration == 0:
                        first_validated_prompt_seconds = time.perf_counter() - first_prompt_start
                        first_validated_image_seconds = time.perf_counter() - image_start
                        first_validated_run_seconds = time.perf_counter() - first_request_start
                    del masks, scores, low_res_logits
                export_start = time.perf_counter()
                Image.fromarray(selected_masks[0].astype(np.uint8) * 255).save(image_directory / f"{prompt['id']}-mask.png")
                np.save(image_directory / f"{prompt['id']}-native-logits.npy", selected_logits[0])
                selected_logits[0].astype("<f4").tofile(image_directory / f"{prompt['id']}-logits.f32")
                export_seconds = time.perf_counter() - export_start
                prompt_report = {"id": prompt["id"], "boxNormalized": prompt.get("box"),
                    "pointsNormalized": point_values, "boxSourcePixels": None if box is None else box.tolist(),
                    "pointsSourcePixels": None if points is None else points.tolist(),
                    "boxPromptFrame": None if box is None else predictor.apply_boxes(box).tolist(),
                    "pointsPromptFrame": None if points is None else predictor.apply_coords(points).tolist(),
                    "predictions": predictions, "scoresByRepeat": scores_by_repeat,
                    "selectedMaskIndices": selections, "nativeLogitsShape": list(selected_logits[0].shape),
                    "sourceMaskShape": list(selected_masks[0].shape),
                    "maximumLogitDifferenceAcrossRepeats": max([float(np.max(np.abs(x-selected_logits[0]))) for x in selected_logits[1:]] or [0.0]),
                    "differentBinaryPixelsAcrossRepeats": max([int(np.count_nonzero(x != selected_masks[0])) for x in selected_masks[1:]] or [0]),
                    "firstValidatedPromptSeconds": first_validated_prompt_seconds,
                    "imageRequestToFirstValidatedMaskSeconds": first_validated_image_seconds,
                    "runToFirstValidatedMaskSeconds": first_validated_run_seconds, "exportSeconds": export_seconds}
                prompt_reports.append(prompt_report)
            memory_samples.append(memory())
            report = {"id": item["id"], "target": item.get("target"), "imageIndex": image_index,
                "width": original_w, "height": original_h, "decodeSeconds": decode_seconds,
                "setImageSeconds": set_seconds, "encoderKernelSeconds": encoder_kernel_seconds,
                "encoderInputShape": phases.encoder_shapes[-1], "promptFrameInputSizeHW": list(predictor.input_size),
                "repeatEncoderFirstProbe": repeat_encoder, "prompts": prompt_reports, "memory": memory_samples[-1]}
            reports.append(report)
            write_json(image_directory / "benchmark.json", report)
            print(json.dumps(report), flush=True)
            del image
    for handle in phases.handles:
        handle.remove()
    package_versions = versions()
    report = {"model": "Official EfficientViT-SAM-L1", "sourceRepository": MODEL_REPOSITORY,
        "sourceRevision": MODEL_REVISION, "checkpointSHA256": MODEL_SHA256, "checkpointBytes": MODEL_BYTES,
        "efficientvitCodeRevision": EFFICIENTVIT_REVISION, "segmentAnythingCodeRevision": SAM_REVISION,
        "sourceVerification": source_verification,
        "officialFactory": "create_sam_model('l1', pretrained=False)",
        "normalizationEpsilons": sorted({float(m.eps) for m in model.modules() if hasattr(m, "eps")}),
        "sourceCompatibilityNote": "Official unmodified 2024-10-15 pre-DC-AE source; reviewed 2025-09-05 repohead imports CUDA/Triton unconditionally and fails on macOS before inference. Current PyTorch/HFHub remain in use.",
        "officialPredictor": "EfficientViTSamPredictor.predict", "device": args.device,
        "mpsFallbackEnabled": False, "precision": "Float32", "autocast": False,
        "encoderInputSide": 512, "promptFrameSide": 1024, "parameterCount": sum(p.numel() for p in model.parameters()),
        "torchThreads": torch.get_num_threads(), "torchInteropThreads": torch.get_num_interop_threads(),
        "pythonVersion": platform.python_version(), "packageVersions": package_versions,
        "importSeconds": import_seconds, "modelBuildAndStrictCPUWeightLoadSeconds": build_load_cpu_seconds,
        "modelDeviceTransferSeconds": transfer_seconds, "images": reports,
        "elapsedSecondsIncludingImportsAndOutputs": time.perf_counter() - started,
        "processPeakResidentBytes": max(x["processPeakResidentBytes"] for x in memory_samples),
        "maximumSampledMPSDriverAllocatedBytes": max([x.get("mpsDriverAllocatedBytes", 0) for x in memory_samples]),
        "limitations": "Serial photo evaluation, one cached image embedding per image, two identical prompt decodes without mask_input refinement. Optional first-image encoder repeat is a separate probe. Manual source-pixel box/points, not VLM grounding or text segmentation. Official 512 longest-side/ImageNet-normalized corner-padded encoder and separate rounded 1024 prompt frame/postprocessing. Forward hooks synchronize MPS before and after each stage; stage kernel measurements exclude some work between modules. predictSeconds includes official postprocessing, source-resolution restoration and NumPy CPU copies, not just the decoder. imageRequestToFirstValidatedMaskSeconds includes decode/set_image/first validated result and optional encoder probe, excludes mask file export. Float32 without autocast; no MPS CPU fallback. OS/device caches not purged; initial graph work is not a controlled cold start. macOS process peak RSS excludes some driver/GPU memory; MPS driver values are sampled, not true peaks. No ground-truth masks or broad quality benchmark. Native logits are segmentation confidence, not alpha mattes."}
    write_json(args.output / "benchmark.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    dl = subparsers.add_parser("download")
    dl.add_argument("root", type=Path)
    runner = subparsers.add_parser("run")
    runner.add_argument("root", type=Path)
    runner.add_argument("manifest", type=Path)
    runner.add_argument("output", type=Path)
    runner.add_argument("--device", choices=["mps", "cpu"], required=True)
    runner.add_argument("--only", help="Optional single fixture ID for a labelled probe")
    runner.add_argument("--repeat-encoder-first", action="store_true")
    args = parser.parse_args()
    if args.command == "download":
        download(args.root.resolve())
    else:
        run(args)


if __name__ == "__main__":
    main()

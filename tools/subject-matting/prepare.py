#!/usr/bin/env python3
"""Prepare PicEdit's pinned, fully local BiRefNet HR matting Core ML model.

Only the three checksum-pinned upstream files are downloaded/executed; model
weights use safetensors, never pickle. No photograph or telemetry is uploaded.
The Python environment is needed only by developers, never by PicEdit itself.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import types
import urllib.request
import uuid

REVISION = "5d6b6f8adcb5b417c871b1d84ceaae9871355b7f"
REPOSITORY = "ZhengPeng7/BiRefNet_HR-matting"
FILES = {
    "birefnet.py": "2a45b4e0ece72d7c4212bca1a988e7d7e52bfe9f98ec59c58b8809c8a8b7a831",
    "BiRefNet_config.py": "e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52",
    "model.safetensors": "a5a4de698739ea5e0e8bbab28e1b293dde95092b87a442d566cbc585c53cef55",
}
SIZE = 1920
MAX_SIDE = 2048


def model_side(value) -> int:
    side = int(value)
    # The full-resolution Swin encoder has stride 32. The decoder folds the
    # input into 32x32 channel patches, so arbitrary padded sizes would change
    # its learned input-channel contract. Window attention pads independently.
    if not 256 <= side <= MAX_SIDE or side % 32:
        raise argparse.ArgumentTypeError("side must be a multiple of 32 between 256 and 2048")
    return side


def canonicalize_package(output: Path) -> None:
    """Replace packaging UUIDs and protobuf map order with reproducible bytes."""
    import coremltools as ct

    manifest_path = output / "Manifest.json"
    manifest = json.loads(manifest_path.read_text())
    identifiers = {old: str(uuid.uuid5(uuid.NAMESPACE_URL, "picedit-subject-matting-v1:" + entry["path"]))
                   for old, entry in manifest["itemInfoEntries"].items()}
    manifest["itemInfoEntries"] = {identifiers[old]: entry for old, entry in manifest["itemInfoEntries"].items()}
    manifest["rootModelIdentifier"] = identifiers[manifest["rootModelIdentifier"]]
    # Apple's package loader rewrites JSON with four-space indentation and a
    # trailing newline. Use that representation so import/compile is stable.
    manifest_path.write_text(json.dumps(manifest, indent=4, sort_keys=True) + "\n")
    model_path = output / "Data/com.apple.CoreML/model.mlmodel"
    spec = ct.proto.Model_pb2.Model()
    spec.ParseFromString(model_path.read_bytes())
    model_path.write_bytes(spec.SerializeToString(deterministic=True))


def digest(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def pinned_bytes(directory: Path, name: str) -> bytes:
    path = directory / name
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Invalid pinned source: {path}")
    value = path.read_bytes()
    if hashlib.sha256(value).hexdigest() != FILES[name]:
        raise ValueError(f"Pinned source checksum mismatch: {path}")
    return value


def sources(directory: Path, download: bool) -> None:
    if directory.is_symlink():
        raise ValueError("Source directory must not be a symbolic link")
    directory.mkdir(parents=True, exist_ok=True)
    for name, expected in FILES.items():
        target = directory / name
        if not target.exists():
            if not download:
                raise ValueError(f"Missing {target}; use --download to fetch pinned public files")
            temporary = None
            url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}"
            try:
                total = 0
                with tempfile.NamedTemporaryFile(prefix=name + ".", suffix=".partial", dir=directory,
                                                 delete=False) as out:
                    temporary = Path(out.name)
                    with urllib.request.urlopen(url, timeout=60) as response:
                        while chunk := response.read(1024 * 1024):
                            total += len(chunk)
                            if total > 512 * 1024 * 1024:
                                raise ValueError("Source download exceeds 512 MiB")
                            out.write(chunk)
                if digest(temporary) != expected:
                    raise ValueError(f"Checksum mismatch: {name}")
                # Hard-link creation refuses an existing destination atomically;
                # a racing preparer can never have its file overwritten.
                os.link(temporary, target)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        if target.is_symlink() or not target.is_file() or digest(target) != expected:
            raise ValueError(f"Pinned source checksum mismatch: {target}")


def load_upstream_classes(directory: Path):
    # Never place the caller-selected source directory on sys.path: otherwise
    # unpinned files there could shadow dependencies imported by verified code.
    config_name = "_picedit_pinned_birefnet_config"
    configuration = types.ModuleType(config_name)
    config_path = directory / "BiRefNet_config.py"
    exec(compile(pinned_bytes(directory, "BiRefNet_config.py"), str(config_path), "exec"), configuration.__dict__)
    code = pinned_bytes(directory, "birefnet.py").decode("utf-8")
    code = code.replace("from .BiRefNet_config import BiRefNetConfig",
                        f"from {config_name} import BiRefNetConfig")
    namespace = {"__name__": "picedit_pinned_birefnet"}
    previous = sys.modules.get(config_name)
    sys.modules[config_name] = configuration
    try:
        exec(compile(code, str(directory / "birefnet.py"), "exec"), namespace)
    finally:
        if previous is None:
            del sys.modules[config_name]
        else:
            sys.modules[config_name] = previous
    return namespace


def load_model(directory: Path):
    import torch
    from safetensors.torch import load

    namespace = load_upstream_classes(directory)
    model = namespace["BiRefNet"](config=namespace["BiRefNetConfig"](bb_pretrained=False))
    model.load_state_dict(load(pinned_bytes(directory, "model.safetensors")), strict=True)
    model.eval()

    class Matting(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = model
            self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).reshape(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).reshape(1, 3, 1, 1))

        def forward(self, image):
            return self.model((image - self.mean) / self.std)[-1].sigmoid().float()

    return Matting().eval()


def publish_directory(source: Path, destination: Path) -> None:
    """macOS atomic no-replace directory rename, including empty destinations."""
    if sys.platform != "darwin":
        raise ValueError("Core ML package publication requires macOS")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def convert(directory: Path, output: Path, side: int = SIZE) -> None:
    side = model_side(side)
    import coremltools as ct
    import numpy as np
    import torch
    from deform_conv_grid_sample import register_deform_conv2d_real

    report_path = output.with_suffix(".inventory.json")
    if output.exists() or output.is_symlink() or report_path.exists() or report_path.is_symlink():
        raise ValueError(f"Refusing to overwrite {output}")
    # CPU tracing uses bounded threads because torchvision deform-conv has no MPS
    # implementation. Model inference in the shipped app uses native Core ML.
    torch.set_num_threads(min(8, os.cpu_count() or 1))
    torch.manual_seed(0)
    model = load_model(directory)
    example = torch.zeros((1, 3, side, side), dtype=torch.float32)
    print("Tracing pinned model on CPU…", flush=True)
    with torch.inference_mode():
        traced = torch.jit.trace(model, example, check_trace=False)
    register_deform_conv2d_real()
    pipeline = ct.PassPipeline.DEFAULT
    # Preserve the attention transpose: the fused form can produce non-finite
    # GPU results on current Apple Silicon drivers. Validate real-image parity.
    pipeline.remove_passes(["common::fuse_transpose_matmul"])
    print("Converting exact deform-conv graph…", flush=True)
    converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             color_layout=ct.colorlayout.RGB, scale=1 / 255.0)],
        outputs=[ct.TensorType(name="alpha", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_GPU,
        pass_pipeline=pipeline, skip_model_load=True,
    )
    converted.short_description = "PicEdit BiRefNet HR matting, local foreground alpha"
    converted.author = "Peng Zheng et al.; PicEdit Core ML conversion"
    converted.license = "MIT"
    converted.input_description["image"] = f"sRGB RGB, stretch to {side}x{side}; normalization baked into graph"
    converted.output_description["alpha"] = f"Foreground coverage [1,1,{side},{side}], sigmoid [0,1]"
    converted.user_defined_metadata.update({
        "picedit.subjectMatting.contract": "birefnet-hr-matting-v1",
        "picedit.subjectMatting.sourceRevision": REVISION,
        "picedit.subjectMatting.weightsSHA256": FILES["model.safetensors"],
        "picedit.subjectMatting.preprocessing": "srgb-rgb-imagenet-square",
    })
    # MLModel.save removes existing destinations. Save only within an owned
    # private staging directory, then publish without replacing a racing path.
    with tempfile.TemporaryDirectory(prefix=".picedit-subject-", dir=output.parent) as temporary:
        staged = Path(temporary) / output.name
        converted.save(str(staged))
        canonicalize_package(staged)
        inventory = [{"path": str(path.relative_to(staged)), "byteCount": path.stat().st_size,
                      "sha256": digest(path)} for path in sorted(staged.rglob("*")) if path.is_file()]
        report = {"contract": "birefnet-hr-matting-v1", "repository": REPOSITORY, "revision": REVISION, "inputSide": side,
                  "sourceFiles": FILES, "files": inventory}
        staged_report = Path(temporary) / "inventory.json"
        staged_report.write_text(json.dumps(report, indent=2) + "\n")
        publish_directory(staged, output)
        # If a racing report exists, leave it and the completed model intact.
        # The full inventory is also printed below on successful publication.
        os.link(staged_report, report_path)
    print(json.dumps(report, indent=2), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--side", type=model_side, default=SIZE,
                        help="multiple of 32 from 256 to 2048; defaults to the approved 1920-pixel app interface")
    args = parser.parse_args()
    start = time.monotonic()
    sources(args.source, args.download)
    convert(args.source, args.output, args.side)
    print(f"Prepared in {time.monotonic() - start:.1f}s", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the frozen V9 mask/no-op diagnosis from pinned SDK CPU tensor sources.

No SDK/model build, model download, neural inference or GPU context. Outputs are
new private evidence outside the repository; previous evidence is preserved.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

TOOLS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sdxl_probe_builder", TOOLS / "build_native.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)
PreparationError = BUILDER.PreparationError
SOURCE_FILES = ["src/core/tensor.hpp", "src/core/parallel.h", "src/core/parallel.cpp",
                "src/core/rng.hpp", "thirdparty/stb_image.h",
                "src/pipeline/image.cpp", "src/pipeline/diffusion_engine.cpp"]


def verify_source_contract(sources):
    image = sources["src/pipeline/image.cpp"].decode()
    engine = sources["src/pipeline/diffusion_engine.cpp"].decode()
    mask = """if (sd_version_is_inpaint(sd->version)) {
            latent_mask = sd::ops::max_pool_2d(latent_mask,
                                               {3, 3},
                                               {1, 1},
                                               {1, 1});
        }
        latents.denoise_mask = std::move(latent_mask);"""
    selector = """const bool apply_denoise_mask = !denoise_mask.empty() &&
                                    std::any_of(denoise_mask.values().begin(), denoise_mask.values().end(),
                                                [](float value) { return value != 1.f; });"""
    if image.count(mask) != 1 or engine.count(selector) != 1:
        raise PreparationError("Pinned SDK no longer matches the mask/no-op probe source contract")


def run_probe(source_cache, output, compiler=None):
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise PreparationError("--out must be a new absolute directory")
    output = output.resolve()
    repository = BUILDER.REPOSITORY
    if output == repository or repository in output.parents or output in repository.parents:
        raise PreparationError("probe outputs must stay outside the repository")
    archive_entry = BUILDER.SOURCES[0]
    archive = source_cache / archive_entry["name"]
    BUILDER.PREPARATION.verify(archive, archive_entry)
    if BUILDER.PREPARATION.digest(BUILDER.MASK_FIXTURE)[1] != BUILDER.MASK_FIXTURE_SHA256:
        raise PreparationError("Frozen mask fixture SHA-256 mismatch")
    prefix = "stable-diffusion.cpp-" + archive_entry["revision"] + "/"
    sources = {}
    with tarfile.open(archive, "r:gz") as sdk:
        for name in SOURCE_FILES:
            member = sdk.getmember(prefix + name)
            if not member.isfile() or member.size > 2_000_000:
                raise PreparationError("Unexpected pinned CPU probe source entry")
            sources[name] = sdk.extractfile(member).read()
    verify_source_contract(sources)
    compiler = str(Path(compiler).resolve()) if compiler else shutil.which("clang++")
    if not compiler or not Path(compiler).is_file():
        raise PreparationError("clang++ missing; pass --compiler /absolute/path")
    output.mkdir(mode=0o700)
    for name, data in sources.items():
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    probe = output / "sdxl_denoise_mask_probe.cpp"
    probe.write_bytes((TOOLS / probe.name).read_bytes())
    fixture = output / BUILDER.MASK_FIXTURE.name
    fixture.write_bytes(BUILDER.MASK_FIXTURE.read_bytes())
    if BUILDER.PREPARATION.digest(fixture)[1] != BUILDER.MASK_FIXTURE_SHA256:
        raise PreparationError("Frozen mask fixture changed during probe staging")
    binary = output / "sdxl-denoise-mask-probe"
    command = [compiler, "-std=c++17", "-O2", "-I", str(output / "src"),
               "-I", str(output / "thirdparty"), str(probe),
               str(output / "src/core/parallel.cpp"), "-o", str(binary)]
    BUILDER.PREPARATION.run_checked(command, output / "build.log")
    with (output / "probe.json").open("xb") as stdout, (output / "probe-stderr.log").open("xb") as stderr:
        subprocess.run([str(binary), str(fixture)], stdout=stdout, stderr=stderr, check=True)
    result = json.loads((output / "probe.json").read_text())
    if result.get("status") != "pass" or result.get("applyDenoiseMask") is not False:
        raise PreparationError("Native no-op probe failed")
    receipt = {"schemaVersion": 1, "sdkRevision": archive_entry["revision"],
               "archiveSHA256": archive_entry["sha256"],
               "sourceSHA256": {name: hashlib.sha256(data).hexdigest() for name, data in sources.items()},
               "runnerSHA256": BUILDER.PREPARATION.digest(Path(__file__))[1],
               "probeSourceSHA256": BUILDER.PREPARATION.digest(probe)[1],
               "fixtureSHA256": BUILDER.MASK_FIXTURE_SHA256,
               "sourceContractPassed": True, "compileCommand": command, "result": result,
               "scope": "SDK nearest/max-pool primitives and source-matched blend selector; no full image pipeline",
               "modelWeightsLoaded": False, "inferenceExecuted": False, "gpuContextCreated": False}
    BUILDER.PREPARATION.write_json(output / "receipt.json", receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-cache", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--compiler")
    args = parser.parse_args()
    print(json.dumps(run_probe(args.source_cache, args.out, args.compiler), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (PreparationError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("SDXL denoise-mask probe failed: " + str(error), file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env python3
"""Build the separate SDXL evaluator offline from pinned source archives.

No model conversion or inference runs here. Each build extracts a fresh private
source tree and never edits an SDK cache or another evaluation's build outputs.
"""

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


TOOLS = Path(__file__).resolve().parent
REPOSITORY = TOOLS.parent.parent
_SPEC = importlib.util.spec_from_file_location(
    "picedit_image_evaluation_preparation", REPOSITORY / "scripts/prepare-image-generation-evaluation.py")
PREPARATION = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(PREPARATION)
PreparationError = PREPARATION.PreparationError
SOURCES = [
    {"name": "stable-diffusion.cpp.tar.gz", "bytes": 125758115,
     "sha256": "871c4f03286360bf10b9850ce4c57912311d0d91b117d4e4be19d989a417f08b",
     "revision": "8cd731e7b4667eb8f40a153315b9a7125d09a58d", "destination": "source"},
    {"name": "ggml.tar.gz", "bytes": 4158450,
     "sha256": "bbfaebbfe2564a796f1a9309ff87cd6c6a5acdfffe7b779f96b847f57945403b",
     "revision": "d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93", "destination": "source/ggml"},
]


def build(root, cmake=None, source_cache=None):
    if not root.is_absolute() or root.is_symlink():
        raise PreparationError("--root must be an absolute nonsymbolic directory")
    root = root.resolve()
    if root == Path("/") or root == REPOSITORY or REPOSITORY in root.parents:
        raise PreparationError("build outputs must stay outside the repository")
    if not root.is_dir():
        raise PreparationError("evaluation root missing; prepare inputs first")
    helper, receipt, log = (root / name for name in ["sdxl-helper", "native-installation.json", "native-build.log"])
    if any(path.exists() or path.is_symlink() for path in [helper, receipt, log]):
        raise PreparationError("build outputs already exist; preserve them and use a fresh root")
    inputs = root / "inputs"
    archives = source_cache if source_cache is not None else inputs / "downloads"
    if archives.is_symlink() or not archives.is_dir():
        raise PreparationError("verified source archive directory missing or symbolic")
    if source_cache is None and (inputs.is_symlink() or not inputs.is_dir()):
        raise PreparationError("verified inputs directory missing or symbolic")
    # Verification precedes tools or writes, even when a CLI probe supplies a
    # mock compiler. The actual source extraction verifies the hashes again.
    for entry in SOURCES:
        PREPARATION.verify(archives / entry["name"], entry)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise PreparationError("native SDXL evaluation requires Apple Silicon macOS")
    cmake = str(Path(cmake).resolve()) if cmake else shutil.which("cmake")
    if not cmake or not Path(cmake).is_file():
        raise PreparationError("CMake missing; pass --cmake /absolute/path/to/cmake")
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang++"], text=True).strip()
    source_hash = PREPARATION.digest(TOOLS / "helper.cpp")[1]
    builder_hash = PREPARATION.digest(Path(__file__))[1]
    with tempfile.TemporaryDirectory(prefix=".sdxl-native-", dir=root) as directory:
        stage = Path(directory)
        for entry in SOURCES:
            PREPARATION.extract_sources(archives / entry["name"], stage / entry["destination"], entry)
        source, generated = stage / "source", stage / "build"
        # Public SDK API only: no diagnostic patch or private context shim.
        PREPARATION.run_checked([cmake, "-S", str(source), "-B", str(generated),
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_SYSROOT=" + sdk,
            "-DSD_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON", "-DSD_WEBP=OFF", "-DSD_WEBM=OFF",
            "-DSD_SERVER_BUILD_FRONTEND=OFF", "-DSD_BUILD_EXAMPLES=OFF",
            "-DSD_BUILD_SHARED_LIBS=OFF", "-DSD_BUILD_SHARED_GGML_LIB=OFF",
            "-DSD_GGML_SOURCE_DIR=" + str(source / "ggml")], log)
        PREPARATION.run_checked([cmake, "--build", str(generated), "--target", "stable-diffusion", "--parallel", "2"], log)
        staged_helper = stage / "sdxl-helper"
        arguments = [compiler, "-std=gnu++17", "-O3", "-DNDEBUG", "-isysroot", sdk,
                     "-mmacosx-version-min=14.0"]
        for include in [source / "include", source / "thirdparty"]:
            arguments += ["-I", str(include)]
        libraries = [generated / "libstable-diffusion.a", generated / "ggml/src/libggml.a",
            generated / "ggml/src/libggml-cpu.a", generated / "ggml/src/ggml-blas/libggml-blas.a",
            generated / "ggml/src/ggml-metal/libggml-metal.a", generated / "ggml/src/libggml-base.a"]
        # Compile a private copy whose digest is fixed before publication.
        helper_source = stage / "helper.cpp"
        shutil.copyfile(TOOLS / "helper.cpp", helper_source)
        if PREPARATION.digest(helper_source)[1] != source_hash:
            raise PreparationError("helper source changed during build")
        arguments += [str(helper_source), *map(str, libraries), "-framework", "Accelerate",
                      "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalKit",
                      "-o", str(staged_helper)]
        PREPARATION.run_checked(arguments, log)
        staged_helper.chmod(0o700)
        result = {"schemaVersion": 1, "sdkRevision": SOURCES[0]["revision"],
            "ggmlRevision": SOURCES[1]["revision"], "sources": SOURCES,
            "helperSHA256": PREPARATION.digest(staged_helper)[1],
            "helperSourceSHA256": source_hash, "builderSHA256": builder_hash,
            "publicSDKAPIOnly": True, "inferenceExecuted": False, "conversionExecuted": False,
            "productCapability": "unavailable", "buildJobs": 2}
        staged_receipt = stage / "native-installation.json"
        PREPARATION.write_json(staged_receipt, result)
        # No-overwrite publication; readiness is the receipt, linked last.
        os.link(staged_helper, helper)
        try:
            os.link(staged_receipt, receipt)
        except BaseException:
            helper.unlink()
            raise
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--build", required=True, action="store_true", help="explicit offline build; no conversion or inference")
    parser.add_argument("--cmake")
    parser.add_argument("--source-cache", type=Path, help="read-only pinned archive directory; allows building before model installation")
    args = parser.parse_args()
    if not args.root.is_absolute() or not args.root.is_dir() or args.root.is_symlink():
        raise PreparationError("--root must be an existing absolute nonsymbolic directory")
    # This independent build lock is never removed. Foreign builds cannot lose
    # their lock file when a preparation or another evaluation fails.
    lock_path = args.root / ".sdxl-native-build.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PreparationError("another native build uses this root") from error
        print(json.dumps(build(args.root, args.cmake, args.source_cache), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (PreparationError, OSError, ValueError) as error:
        print("SDXL native preparation failed: " + str(error), file=sys.stderr)
        sys.exit(2)

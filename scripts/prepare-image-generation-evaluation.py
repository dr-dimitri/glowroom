#!/usr/bin/env python3
"""Explicit, pinned downloads/builds for the unavailable image-backend evaluation.

Standard-library only. This tool never runs model inference. --build never uses
the network. Model files, source archives and generated binaries stay outside Git.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


REPOSITORY = Path(__file__).resolve().parent.parent
TOOLS = REPOSITORY / "tools/image-generation-evaluation"
BLOCK_BYTES = 1024 * 1024
MINIMUM_RAM = 16 * 1024**3
MINIMUM_DISK = 8 * 1024**3
EXPECTED_PACKAGE_SHA256 = "832801b46a076c7fee3fa895b1d0f369b8335b5a977849a7955a092fc0196db7"


class PreparationError(Exception):
    pass


def digest(path):
    checksum = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(BLOCK_BYTES), b""):
            size += len(block)
            checksum.update(block)
    return size, checksum.hexdigest()


def verify(path, entry):
    if not path.is_file() or path.is_symlink():
        raise PreparationError("missing or symbolic input: " + path.name)
    size, checksum = digest(path)
    if size != entry["bytes"] or checksum != entry["sha256"]:
        raise PreparationError("length/SHA256 mismatch: " + path.name)


def write_json(path, value):
    with path.open("w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def atomic_copy(source, destination, entry):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        verify(destination, entry)
        return
    descriptor, temporary_name = tempfile.mkstemp(prefix=".install-", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as stream:
            shutil.copyfileobj(stream, output, BLOCK_BYTES)
            output.flush()
            os.fsync(output.fileno())
        verify(temporary, entry)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def local_source(cache, entry, model=False):
    if cache is None:
        return None
    paths = [cache / entry["name"]] if not model else [
        cache / "model" / entry["installedPath"],
        cache / "downloads" / "model" / entry["path"],
    ]
    if not model:
        paths.append(cache / "downloads" / entry["name"])
    for path in paths:
        if path.exists():
            verify(path, entry)
            return path
    return None


def download_file(entry, destination, cache=None, model=False, allow_network=True):
    if destination.exists():
        verify(destination, entry)
        return
    cached = local_source(cache, entry, model)
    if cached:
        atomic_copy(cached, destination, entry)
        return
    if not allow_network:
        raise PreparationError("missing verified offline cache file: " + destination.name)
    url = entry["source"]
    if not url.startswith("https://"):
        raise PreparationError("only pinned HTTPS downloads are allowed")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".download-", dir=destination.parent)
    temporary = Path(name)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Glowroom-Image-Evaluation/1"})
        with os.fdopen(descriptor, "wb") as output, urllib.request.urlopen(request, timeout=60) as response:
            if not response.url.startswith("https://"):
                raise PreparationError("insecure download redirect")
            count = 0
            for block in iter(lambda: response.read(BLOCK_BYTES), b""):
                count += len(block)
                if count > entry["bytes"]:
                    raise PreparationError("download exceeds manifest length")
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        verify(temporary, entry)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def preflight(root):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise PreparationError("evaluation requires an Apple Silicon Mac")
    version = tuple(int(part) for part in platform.mac_ver()[0].split(".")[:2])
    if version < (14, 0):
        raise PreparationError("evaluation requires macOS 14 or newer")
    memory = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True).strip())
    free = shutil.disk_usage(root).free
    if memory < MINIMUM_RAM:
        raise PreparationError("evaluation requires at least 16 GiB physical memory")
    if free < MINIMUM_DISK:
        raise PreparationError("evaluation requires at least 8 GiB free disk space")
    # Runtime memory pressure, peak memory and cancellation remain harness gates.
    return {"architecture": "arm64", "macOS": platform.mac_ver()[0],
            "physicalMemoryBytes": memory, "freeDiskBytes": free}


def validate_fixture_archive(archive, package):
    if archive is None or not archive.is_absolute() or not archive.is_dir():
        raise PreparationError("--fixture-archive requires an existing absolute external fixture archive")
    archive = archive.resolve()
    if archive == REPOSITORY or REPOSITORY in archive.parents:
        raise PreparationError("fixture archives must stay outside the repository")
    original = archive / "provenance/fixtures-manifest.json"
    if not original.is_file() or original.is_symlink():
        raise PreparationError("fixture archive missing provenance/fixtures-manifest.json")
    if digest(original)[1] != package["fixtureManifestSHA256"]:
        raise PreparationError("fixture manifest hash mismatch")
    original_manifest = json.loads(original.read_text())
    # Image lengths and hashes are anchored in the separately pinned tool package.
    entries = package["fixtureFiles"]
    if not entries:
        raise PreparationError("missing archived fixtures")
    for entry in entries:
        relative = PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != "fixtures":
            raise PreparationError("invalid pinned fixture path")
        verify(archive / entry["path"], entry)
    if not isinstance(original_manifest, dict):
        raise PreparationError("invalid fixture manifest")
    return archive


def install_fixtures(root, package, archive):
    archive = validate_fixture_archive(archive, package)
    original = archive / "provenance/fixtures-manifest.json"
    for entry in package["fixtureFiles"]:
        atomic_copy(archive / entry["path"], root / entry["path"], entry)
    atomic_copy(original, root / "fixtures-manifest.json", {
        "bytes": original.stat().st_size, "sha256": package["fixtureManifestSHA256"]})


def install_model(root, package, cache, allow_network=True):
    destination = root / "model"
    if destination.exists():
        for entry in package["modelFiles"]:
            verify(destination / entry["installedPath"], entry)
        return
    with tempfile.TemporaryDirectory(prefix=".model-stage-", dir=root) as name:
        stage = Path(name)
        # Two independent streams cap disk/network pressure; publication is serial.
        with ThreadPoolExecutor(max_workers=2) as workers:
            futures = [workers.submit(download_file, entry, stage / entry["installedPath"], cache, True, allow_network)
                       for entry in package["modelFiles"]]
            for future in futures:
                future.result()
        for entry in package["modelFiles"]:
            verify(stage / entry["installedPath"], entry)
        os.replace(stage, destination)


def source_archives(root, package, cache, allow_network):
    for entry in package["sources"]:
        destination = root / "downloads" / entry["name"]
        if allow_network:
            download_file(entry, destination, cache)
        elif destination.exists():
            verify(destination, entry)
        else:
            cached = local_source(cache, entry)
            if cached is None:
                raise PreparationError("missing source archive; run explicit --download first: " + entry["name"])
            atomic_copy(cached, destination, entry)


def extract_sources(archive, destination, expected):
    verify(archive, expected)
    total = 0
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            whole = PurePosixPath(member.name)
            parts = whole.parts[1:]
            if whole.is_absolute() or ".." in whole.parts:
                raise PreparationError("unsafe source archive path")
            if not parts or member.isdir():
                continue
            if member.issym() and "/".join(parts) == ".pi/SYSTEM.md":
                continue  # This SDK metadata link is not a build input; never follow it.
            if not member.isfile() or member.size > 256 * 1024**2:
                raise PreparationError("unsupported source archive entry")
            total += member.size
            if total > 2 * 1024**3:
                raise PreparationError("source archive exceeds extraction limit")
            path = destination.joinpath(*parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            with package.extractfile(member) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output, BLOCK_BYTES)


def run_checked(arguments, log):
    with log.open("ab") as output:
        process = subprocess.Popen(arguments, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait()
        except BaseException:
            # Stop only our own build process group before removing its stage.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        if code != 0:
            raise PreparationError("native build failed; inspect " + log.name)


def build_helper(root, package, cmake, preflight_report, fixture_archive):
    helper = root / "evaluation-helper-current"
    receipt = root / "evaluation-installation.json"
    if helper.exists() or receipt.exists():
        raise PreparationError("helper/receipt already exists; use a fresh evaluation root to preserve it")
    cmake = str(Path(cmake).resolve()) if cmake else shutil.which("cmake")
    if not cmake or not Path(cmake).is_file():
        raise PreparationError("CMake missing; pass --cmake /absolute/path/to/cmake")
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang++"], text=True).strip()
    log = root / "native-build.log"
    if log.exists():
        raise PreparationError("build log already exists; use a fresh evaluation root")
    with tempfile.TemporaryDirectory(prefix=".native-stage-", dir=root) as name:
        stage = Path(name)
        for entry in package["sources"]:
            extract_sources(root / "downloads" / entry["name"], stage / entry["destination"], entry)
        source = stage / "source"
        build = stage / "build"
        # Patch only the isolated extracted source, never the cached SDK/archive.
        run_checked(["/usr/bin/patch", "-p1", "-d", str(source), "-i", str(TOOLS / "native-diagnostics.patch")], log)
        flags = "-I" + shlex.quote(str(TOOLS))
        run_checked([cmake, "-S", str(source), "-B", str(build),
                     "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                     "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_CXX_FLAGS=" + flags,
                     "-DCMAKE_OSX_SYSROOT=" + sdk, "-DSD_METAL=ON",
                     "-DGGML_METAL_EMBED_LIBRARY=ON", "-DSD_WEBP=OFF", "-DSD_WEBM=OFF",
                     "-DSD_SERVER_BUILD_FRONTEND=OFF", "-DSD_BUILD_EXAMPLES=OFF",
                     "-DSD_BUILD_SHARED_LIBS=OFF", "-DSD_BUILD_SHARED_GGML_LIB=OFF",
                     "-DSD_GGML_SOURCE_DIR=" + str(source / "ggml")], log)
        run_checked([cmake, "--build", str(build), "--target", "stable-diffusion", "--parallel", "2"], log)
        includes = [TOOLS, source, source / "src", source / "src/core", source / "src/pipeline",
                    source / "include", source / "ggml/include", source / "ggml/src",
                    source / "thirdparty", source / "thirdparty/oniguruma", source / "thirdparty/utf8proc"]
        arguments = [compiler, "-std=gnu++17", "-O3", "-DNDEBUG", "-DGGML_MAX_NAME=160",
                     "-DGGML_USE_BLAS", "-DGGML_USE_CPU", "-DGGML_USE_METAL", "-DONIG_STATIC",
                     "-DUTF8PROC_STATIC", "-isysroot", sdk, "-mmacosx-version-min=14.0"]
        for include in includes:
            arguments += ["-I", str(include)]
        staged_helper = stage / "evaluation-helper-current"
        libraries = [build / "libstable-diffusion.a", build / "ggml/src/libggml.a",
                     build / "ggml/src/libggml-cpu.a", build / "ggml/src/ggml-blas/libggml-blas.a",
                     build / "ggml/src/ggml-metal/libggml-metal.a", build / "ggml/src/libggml-base.a"]
        arguments += [str(TOOLS / "evaluation-helper-current.cpp"), *map(str, libraries),
                      "-framework", "Accelerate", "-framework", "Foundation",
                      "-framework", "Metal", "-framework", "MetalKit", "-o", str(staged_helper)]
        run_checked(arguments, log)
        staged_helper.chmod(0o700)
        helper_sha = digest(staged_helper)[1]
        install_fixtures(root, package, fixture_archive)
        atomic_copy(TOOLS / "model-manifest.json", root / "model-manifest.json",
                    package["buildInputs"]["model-manifest.json"])
        atomic_copy(TOOLS / "unbatched-configuration.json", root / "unbatched-configuration.json",
                    package["buildInputs"]["unbatched-configuration.json"])
        atomic_copy(TOOLS / "THIRD-PARTY-NOTICES.txt", root / "THIRD-PARTY-NOTICES.txt",
                    package["buildInputs"]["THIRD-PARTY-NOTICES.txt"])
        result = {key: package[key] for key in ["modelManifestSHA256", "configurationSHA256",
                  "sdkRevision", "ggmlRevision", "modelRevision"]}
        result.update({"schemaVersion": 1, "helperSHA256": helper_sha,
                       "helperSourceSHA256": package["buildInputs"]["evaluation-helper-current.cpp"]["sha256"],
                       "configurationFileSHA256": package["buildInputs"]["unbatched-configuration.json"]["sha256"],
                       "fixtureManifestSHA256": package["fixtureManifestSHA256"],
                       "preflight": preflight_report,
                       "modelFilesInstalled": (root / "model").is_dir(),
                       "inferenceExecuted": False, "productCapability": "unavailable"})
        staged_receipt = stage / "evaluation-installation.json"
        write_json(staged_receipt, result)
        os.replace(staged_helper, helper)
        # Receipt is the readiness marker, published last after a successful build.
        os.replace(staged_receipt, receipt)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="absolute external evaluation directory")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--download", action="store_true", help="explicitly install pinned sources and 2.13 GB model")
    action.add_argument("--build", action="store_true", help="build from already downloaded/verified cached sources; no network")
    parser.add_argument("--fixture-archive", type=Path, required=True,
                        help="external archive containing provenance/fixtures-manifest.json and fixtures/")
    parser.add_argument("--source-cache", type=Path, help="read-only verified local archive/model cache")
    parser.add_argument("--offline", action="store_true", help="refuse every network request, including explicit downloads")
    parser.add_argument("--cmake", help="explicit CMake executable for --build")
    arguments = parser.parse_args()
    if not arguments.root.is_absolute():
        raise PreparationError("--root must be absolute")
    root = arguments.root.resolve()
    if root == Path("/") or root == REPOSITORY or REPOSITORY in root.parents:
        raise PreparationError("generated evaluation resources must stay outside the repository")
    package_path = TOOLS / "evaluation-package.json"
    if digest(package_path)[1] != EXPECTED_PACKAGE_SHA256:
        raise PreparationError("pinned evaluation package manifest SHA256 mismatch")
    package = json.loads(package_path.read_text())
    fixture_archive = validate_fixture_archive(arguments.fixture_archive, package)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache = arguments.source_cache.resolve() if arguments.source_cache else None
    with (root / ".prepare-image-generation.lock").open("a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PreparationError("another preparation uses this evaluation root") from error
        report = preflight(root)
        for filename, entry in package["buildInputs"].items():
            verify(TOOLS / filename, entry)
        source_archives(root, package, cache, arguments.download and not arguments.offline)
        if arguments.download:
            install_model(root, package, cache, not arguments.offline)
            atomic_copy(TOOLS / "model-manifest.json", root / "model-manifest.json",
                        package["buildInputs"]["model-manifest.json"])
            atomic_copy(TOOLS / "unbatched-configuration.json", root / "unbatched-configuration.json",
                        package["buildInputs"]["unbatched-configuration.json"])
            install_fixtures(root, package, fixture_archive)
            report.update({"status": "downloaded-verified-no-build-no-inference",
                           "modelRevision": package["modelRevision"]})
        else:
            report = build_helper(root, package, arguments.cmake, report, fixture_archive)
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (PreparationError, OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        print("Image evaluation preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)

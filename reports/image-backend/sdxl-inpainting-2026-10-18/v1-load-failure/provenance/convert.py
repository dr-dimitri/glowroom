#!/usr/bin/env python3
"""Explicit offline SDXL Q8 preparation; never load an inference context."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time


TOOLS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sdxl_conversion_preparation", TOOLS / "prepare.py")
PREPARATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARATION)
PreparationError = PREPARATION.PreparationError
EXPECTED_PACKAGE_SHA256 = "d66209fbcb767950b36f815c6148c01193b3e297808d6bf56eadf0cb8a39e7ac"
MAX_CONVERSION_SECONDS = 600
VAE_RULES = r"^(first_stage_model\.|vae\.)=f32"


def digest_file(path, expected_size=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise PreparationError("Expected singly linked regular file: " + str(path))
        if expected_size is not None and metadata.st_size != expected_size:
            raise PreparationError("Pinned file size mismatch: " + str(path))
        digest = hashlib.sha256()
        count = 0
        while block := stream.read(PREPARATION.CHUNK_SIZE):
            count += len(block)
            digest.update(block)
        if count != metadata.st_size:
            raise PreparationError("File changed while hashing: " + str(path))
        return count, digest.hexdigest()


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size > 1024 * 1024:
            raise PreparationError("Invalid preparation receipt: " + str(path))
        result = json.load(stream)
        if not isinstance(result, dict):
            raise PreparationError("Expected JSON receipt object: " + str(path))
        return result


def verify_inputs(root, package):
    inputs = root / "inputs"
    if inputs.is_symlink() or not inputs.is_dir():
        raise PreparationError("Verified inputs missing or symbolic")

    def verify(entry):
        relative = PREPARATION.relative_path(entry["path"])
        digest = hashlib.sha256()
        count = 0
        with PREPARATION.open_cached(inputs, relative) as source:
            if os.fstat(source.fileno()).st_size != entry["bytes"]:
                raise PreparationError("Pinned input size mismatch: " + entry["path"])
            while block := source.read(PREPARATION.CHUNK_SIZE):
                count += len(block)
                digest.update(block)
        if count != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
            raise PreparationError("Pinned input SHA-256 mismatch: " + entry["path"])

    # Two independent streams overlap disk access without competing model work.
    with ThreadPoolExecutor(max_workers=2) as workers:
        list(workers.map(verify, package["files"]))
    installation = read_json(inputs / "installation.json")
    for key in ["purpose", "model", "revision", "files"]:
        if installation.get(key) != package[key]:
            raise PreparationError("Input installation receipt does not match pinned package")


def verify_native(root, package):
    native = read_json(root / "native-installation.json")
    for key in ["sdkRevision", "ggmlRevision"]:
        if native.get(key) != package[key]:
            raise PreparationError("Native SDK provenance mismatch")
    helper = root / "sdxl-helper"
    helper_hash = digest_file(helper)[1]
    source_hash = digest_file(TOOLS / "helper.cpp")[1]
    if (native.get("helperSHA256") != helper_hash or native.get("helperSourceSHA256") != source_hash or
            native.get("publicSDKAPIOnly") is not True):
        raise PreparationError("Native helper or source SHA-256 mismatch")
    if not os.access(helper, os.X_OK):
        raise PreparationError("Native helper is not executable")
    return helper, helper_hash, source_hash


def validated_event(path, model_bytes):
    # The separate native converter emits exactly one bounded JSON event. The
    # raw file is preserved; no SDK diagnostics are filtered into the protocol.
    if path.stat().st_size > 65537:
        raise PreparationError("Unexpected conversion event length")
    lines = path.read_bytes().splitlines()
    if len(lines) != 1:
        raise PreparationError("Expected exactly one native conversion event")
    event = json.loads(lines[0])
    if (not isinstance(event, dict) or type(event.get("protocol")) is not int or event.get("protocol") != 1 or
            event.get("event") != "converted" or event.get("status") != "success" or
            event.get("output") != "model-q8_0.gguf" or event.get("conversionType") != "q8_0" or
            event.get("tensorTypeRules") != VAE_RULES or type(event.get("threads")) is not int or event.get("threads") != 2 or
            type(event.get("bytes")) is not int or event.get("bytes") != model_bytes or event.get("inferenceExecuted") is not False):
        raise PreparationError("Native conversion event does not match the Q8/VAE-F32 contract")
    seconds = event.get("seconds")
    if (isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or
            not math.isfinite(seconds) or seconds < 0 or seconds > MAX_CONVERSION_SECONDS):
        raise PreparationError("Invalid native conversion time")
    if "tensorTypeCounts" in event:
        counts = event["tensorTypeCounts"]
        if (not isinstance(counts, dict) or not counts or
                any(kind not in {"f32", "f16", "q8_0"} or isinstance(count, bool) or
                    not isinstance(count, int) or count <= 0 for kind, count in counts.items()) or
                counts.get("q8_0", 0) == 0 or counts.get("f32", 0) == 0):
            raise PreparationError("Invalid native quantized tensor types")
    return event


def exclusive_output(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    return os.fdopen(descriptor, "wb")


def publish_receipt(root, receipt):
    descriptor, name = tempfile.mkstemp(prefix=".sdxl-conversion-receipt-", dir=root)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(receipt, stream, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # Linking publishes complete bytes atomically and refuses to overwrite a
        # receipt that appeared meanwhile. The private temporary is ours only.
        os.link(temporary, root / "conversion.json")
    finally:
        temporary.unlink()


def convert(root):
    root = PREPARATION.external_root(root)
    metadata = root.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise PreparationError("Conversion root must be an owned private directory")
    outputs = [root / name for name in ["model-q8_0.gguf", "conversion.json",
                                       "conversion-events.jsonl", "conversion-stderr.bin"]]
    if any(path.exists() or path.is_symlink() for path in outputs):
        raise PreparationError("Conversion output exists; preserve it and use a fresh root")
    lock = root / ".sdxl-conversion.lock"
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    owned_lock = os.fstat(descriptor)
    try:
        package = PREPARATION.load_package()
        if digest_file(TOOLS / "package.json")[1] != EXPECTED_PACKAGE_SHA256:
            raise PreparationError("Pinned source package changed")
        verify_inputs(root, package)
        helper, helper_hash, source_hash = verify_native(root, package)
        if any(path.exists() or path.is_symlink() for path in outputs):
            raise PreparationError("Conversion output appeared during verification")
        started = time.monotonic()
        with exclusive_output(outputs[2]) as events, exclusive_output(outputs[3]) as errors:
            process = subprocess.Popen([str(helper), "--convert", str(root)], stdin=subprocess.DEVNULL,
                                       stdout=events, stderr=errors)
            try:
                result = process.wait(timeout=MAX_CONVERSION_SECONDS)
            except BaseException:
                # The public C API converter creates threads, not child
                # processes. Reap this exact helper before returning any error.
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                finally:
                    process.wait()
                raise
        seconds = time.monotonic() - started
        if result != 0:
            raise PreparationError("Native conversion failed; raw logs were preserved")
        model_bytes, model_hash = digest_file(outputs[0])
        with outputs[0].open("rb") as model:
            if model.read(4) != b"GGUF":
                raise PreparationError("Native output is not a GGUF model")
        event = validated_event(outputs[2], model_bytes)
        receipt = {"schemaVersion": 1, "purpose": "offline-sdxl-q8-preparation-only",
                   "sourcePackageSHA256": EXPECTED_PACKAGE_SHA256,
                   "helperSHA256": helper_hash, "helperSourceSHA256": source_hash,
                   "modelSHA256": model_hash, "modelBytes": model_bytes,
                   "conversionSeconds": seconds, "native": event,
                   "processScope": "observed direct converter helper only; no inference context or product capability tested",
                   "maximumConversionSeconds": MAX_CONVERSION_SECONDS,
                   "inferenceExecuted": False, "productCapability": "unavailable"}
        publish_receipt(root, receipt)
        return receipt
    finally:
        os.close(descriptor)
        try:
            current = lock.lstat()
            if (current.st_dev, current.st_ino) == (owned_lock.st_dev, owned_lock.st_ino):
                lock.unlink()
        except FileNotFoundError:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="existing private evaluation root outside the repository")
    parser.add_argument("--convert", action="store_true", help="explicit offline conversion; no inference")
    args = parser.parse_args(argv)
    if not args.convert:
        print(json.dumps({"action": "plan", "network": False, "conversionExecuted": False,
                          "sourcePackageSHA256": EXPECTED_PACKAGE_SHA256,
                          "maximumConversionSeconds": MAX_CONVERSION_SECONDS,
                          "command": "sdxl-helper --convert <evaluation-root>"}, indent=2))
        return 0
    try:
        if not args.root:
            raise PreparationError("Conversion requires --root")
        print(json.dumps(convert(args.root), sort_keys=True, allow_nan=False))
        return 0
    except (PreparationError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("SDXL conversion preparation failed: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

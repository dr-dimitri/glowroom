#!/usr/bin/env python3
"""Pinned SDXL evaluation inputs; download only, no compilation/conversion/inference."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import urllib.parse
import urllib.request


TOOLS = Path(__file__).resolve().parent
REPOSITORY = TOOLS.parents[1]
EXPECTED_PACKAGE_SHA256 = "d66209fbcb767950b36f815c6148c01193b3e297808d6bf56eadf0cb8a39e7ac"
CHUNK_SIZE = 64 * 1024


class PreparationError(Exception):
    pass


def load_package():
    data = (TOOLS / "package.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED_PACKAGE_SHA256:
        raise PreparationError("Pinned package manifest was changed")
    return json.loads(data)


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) != value:
        raise PreparationError("Invalid package path")
    return path


def external_root(value):
    requested = Path(value).expanduser().absolute()
    if requested.is_symlink():
        raise PreparationError("Evaluation root must not be a symbolic link")
    root = requested.resolve()
    if root == REPOSITORY or REPOSITORY in root.parents or root in REPOSITORY.parents:
        raise PreparationError("Evaluation root must be outside the repository")
    return root


def open_cached(cache, relative):
    """Walk only real directories and open a singly linked regular source file."""
    if cache.is_symlink():
        raise PreparationError("Source cache must not be a symbolic link")
    directory = os.open(cache, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in relative.parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        source = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=directory)
        try:
            metadata = os.fstat(source)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise PreparationError("Cached payload must be a singly linked regular file")
            return os.fdopen(source, "rb")
        except BaseException:
            os.close(source)
            raise
    finally:
        os.close(directory)


def transfer(package, entry, staging, cache, allow_network):
    relative = relative_path(entry["path"])
    destination = staging.joinpath(*relative.parts)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if cache is not None:
        source = open_cached(cache, relative)
    elif allow_network:
        url = entry["source"]
        if urllib.parse.urlsplit(url).scheme != "https":
            raise PreparationError("Pinned source must use HTTPS")
        source = urllib.request.urlopen(url, timeout=60)
        if urllib.parse.urlsplit(source.geturl()).scheme != "https":
            source.close()
            raise PreparationError("Download redirected outside HTTPS")
    else:
        raise PreparationError("Offline installation requires --source-cache")
    digest = hashlib.sha256()
    count = 0
    with source, destination.open("xb") as output:
        while True:
            block = source.read(min(CHUNK_SIZE, entry["bytes"] + 1 - count))
            if not block:
                break
            count += len(block)
            if count > entry["bytes"]:
                raise PreparationError("Payload exceeds pinned size: " + entry["path"])
            digest.update(block)
            output.write(block)
        output.flush()
        os.fsync(output.fileno())
    if count != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
        raise PreparationError("Payload size or SHA-256 mismatch: " + entry["path"])


def install(package, root, cache=None, allow_network=False):
    root = external_root(root)
    cache = Path(cache).expanduser().absolute() if cache is not None else None
    if cache is None and not allow_network:
        raise PreparationError("Offline installation requires --source-cache")
    paths = [str(relative_path(entry["path"])) for entry in package["files"]]
    if len(paths) != len(set(paths)):
        raise PreparationError("Duplicate package path")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise PreparationError("Evaluation root must be an owned directory without group/other write access")
    lock = root / ".installation.lock"
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError as error:
        raise PreparationError("Another installation owns the evaluation root") from error
    staging = None
    try:
        os.close(descriptor)
        target = root / "inputs"
        if target.exists() or target.is_symlink():
            raise PreparationError("Model destination already exists; refusing to replace it")
        staging = Path(tempfile.mkdtemp(prefix=".sdxl-install-", dir=root))
        # Independent transfers overlap at most two I/O streams; no model work runs here.
        with ThreadPoolExecutor(max_workers=2) as workers:
            futures = [workers.submit(transfer, package, entry, staging, cache, allow_network)
                       for entry in package["files"]]
            for future in futures:
                future.result()
        receipt = {"schemaVersion": 1, "purpose": package["purpose"],
                   "model": package["model"], "revision": package["revision"],
                   "files": package["files"]}
        (staging / "installation.json").write_text(json.dumps(receipt, indent=2) + "\n")
        # The root admission lock covers this existence check and atomic rename.
        if target.exists() or target.is_symlink():
            raise PreparationError("Model destination appeared during installation")
        staging.rename(target)
        staging = None
        return target
    finally:
        if staging is not None:
            shutil.rmtree(staging)
        lock.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="evaluation directory outside the repository")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--download", action="store_true", help="explicitly download pinned data")
    mode.add_argument("--offline", action="store_true", help="install only from --source-cache")
    parser.add_argument("--source-cache", help="directory mirroring the pinned repository paths")
    args = parser.parse_args(argv)
    try:
        package = load_package()
        if not args.download and not args.offline:
            print(json.dumps({"action": "plan", "network": False,
                              "totalBytes": sum(entry["bytes"] for entry in package["files"]),
                              **package}, indent=2))
            return 0
        if not args.root:
            raise PreparationError("Installation requires --root")
        if args.download and args.source_cache:
            raise PreparationError("Use --offline with --source-cache")
        result = install(package, args.root, args.source_cache, args.download)
        print(json.dumps({"action": "installed", "inputs": str(result),
                          "purpose": package["purpose"]}, indent=2))
        return 0
    except (PreparationError, OSError, ValueError) as error:
        print("Preparation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

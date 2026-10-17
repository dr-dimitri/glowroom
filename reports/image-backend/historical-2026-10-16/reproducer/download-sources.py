"""Pinned native evaluation sources, with Git-blob integrity verification."""
from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import tarfile
import urllib.request

ROOT = Path(__file__).parent
SOURCES = [
    ("leejet/stable-diffusion.cpp", "8cd731e7b4667eb8f40a153315b9a7125d09a58d", ROOT / "source", Path("/private/tmp/picedit-inpaint-code-tree.json")),
    ("leejet/ggml", "d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93", ROOT / "source/ggml", Path("/private/tmp/picedit-inpaint-ggml-tree.json")),
]

reports = []
for repository, revision, destination, treepath in SOURCES:
    tree = {e["path"]: e for e in json.loads(treepath.read_text())["tree"] if e["type"] == "blob"}
    archive = ROOT / (repository.split("/")[-1] + ".tar.gz")
    if not archive.exists():
        request = urllib.request.Request(f"https://codeload.github.com/{repository}/tar.gz/{revision}", headers={"User-Agent": "PicEdit-Inpainting-Gate/1"})
        temporary = archive.with_suffix(".partial")
        count = 0
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                count += len(block)
                if count > 512 * 1024 * 1024:
                    raise ValueError("source archive exceeds evaluation limit")
                output.write(block)
        temporary.replace(archive)
    files = 0
    skipped_symlinks = []
    with tarfile.open(archive) as package:
        for member in package:
            parts = PurePosixPath(member.name).parts[1:]
            if not parts or member.isdir():
                continue
            if ".." in parts:
                raise ValueError("nonregular source archive member")
            relative = "/".join(parts)
            expected = tree.get(relative)
            if expected is None:
                raise ValueError(f"unlisted source archive file: {relative}")
            if member.issym():
                data = member.linkname.encode()
                blobhash = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
                if expected.get("mode") != "120000" or blobhash != expected["sha"]:
                    raise ValueError(f"source symlink blob mismatch: {relative}")
                # Instruction metadata is not a build input. Do not materialize
                # source-tree symlinks or follow their targets during extraction.
                skipped_symlinks.append(relative)
                continue
            if not member.isfile():
                raise ValueError("nonregular source archive member")
            data = package.extractfile(member).read()
            blobhash = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
            if blobhash != expected["sha"] or len(data) != expected["size"]:
                raise ValueError(f"source Git blob mismatch: {relative}")
            output = destination.joinpath(*parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            files += 1
    reports.append({"repository": repository, "revision": revision, "sourceArchiveBytes": archive.stat().st_size, "sourceArchiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(), "verifiedRegularFiles": files, "verifiedSkippedSymlinks": skipped_symlinks})
(ROOT / "source-download-report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports, indent=2))


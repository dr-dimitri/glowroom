"""Explicit pinned public downloads; separate from execution, no HF client/auth.

Two independent transfers max; streaming hash/length validation; final path is
published only after full verification. No pickle or model code is executed.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import os
import urllib.request

ROOT = Path(__file__).parent
MANIFEST = json.loads((ROOT / "model-manifest.json").read_text())
DEST = ROOT / "model"


def verify(path, f):
    if not path.is_file() or path.stat().st_size != f["bytes"]:
        return False
    sha = hashlib.sha256()
    git = hashlib.sha1(f'blob {f["bytes"]}\0'.encode())
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
            git.update(block)
    if "sha256" in f:
        return sha.hexdigest() == f["sha256"]
    return git.hexdigest() == f["gitBlobSHA1"]


def download(f):
    output = DEST / f["installedPath"]
    output.parent.mkdir(parents=True, exist_ok=True)
    if verify(output, f):
        return {"path": f["installedPath"], "status": "already-verified", "bytes": f["bytes"]}
    temporary = output.with_name(output.name + ".partial")
    request = urllib.request.Request(f["source"], headers={"User-Agent": "PicEdit-Local-Inpainting-Evaluation/1"})
    received = 0
    try:
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as stream:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                received += len(block)
                if received > f["bytes"]:
                    raise ValueError("public download exceeds fixed byte count")
                stream.write(block)
            stream.flush()
            os.fsync(stream.fileno())
        if not verify(temporary, f):
            raise ValueError("public download hash or byte count differs")
        temporary.replace(output)
        return {"path": f["installedPath"], "status": "downloaded-and-verified", "bytes": received}
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(download, MANIFEST["files"]))
    (ROOT / "download-report.json").write_text(json.dumps({"files": results, "totalBytes": sum(r["bytes"] for r in results)}, indent=2) + "\n")
    for result in results:
        print(json.dumps(result), flush=True)


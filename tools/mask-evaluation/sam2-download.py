#!/usr/bin/env python3
"""Download only pinned public SAM 2.1 Tiny model files; never read test images."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

REVISION = "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306"
REPOSITORY = "apple/coreml-sam2.1-tiny"
FILES = {
    "ImageEncoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 154372, "6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7"),
        ("Data/com.apple.CoreML/weights/weight.bin", 67069504, "eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97"),
        ("Manifest.json", 617, "dd72aa75e3f2f92d0653696bf4d8350d87690d92b116b34912fe640f2b116e08"),
    ),
    "MaskDecoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 75167, "4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577"),
        ("Data/com.apple.CoreML/weights/weight.bin", 10222400, "f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de"),
        ("Manifest.json", 617, "dc6121b61ac560498080d55f9d5fb293cdb305f942a85adb5b71dc8e9d14a8aa"),
    ),
    "PromptEncoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 20618, "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"),
        ("Data/com.apple.CoreML/weights/weight.bin", 2101056, "af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2"),
        ("Manifest.json", 617, "0c0f9b80f0445017dac52f81e93aeb50b9c2c9918708c882df4a65671fda2bd4"),
    ),
}


def download(entry):
    root, name, relative, size, expected = entry
    model_path = f"SAM2_1Tiny{name}FLOAT16.mlpackage/{relative}"
    url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{model_path}"
    target = root / model_path
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".download")
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
        actual_size = temporary.stat().st_size
        actual_hash = hashlib.sha256(temporary.read_bytes()).hexdigest()
        if actual_size != size or actual_hash != expected:
            raise ValueError(f"Integrity mismatch: {model_path}")
        temporary.replace(target)
        return {"path": model_path, "bytes": actual_size, "sha256": actual_hash, "url": url}
    finally:
        temporary.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: sam2-download.py OUTPUT_MODEL_DIRECTORY")
    root = Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    entries = [(root, name, path, size, digest) for name, files in FILES.items()
               for path, size, digest in files]
    # Downloads are independent; three workers bound network and memory usage.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(download, entries))
    provenance = {"repository": REPOSITORY, "revision": REVISION,
                  "license": "Apache-2.0", "files": results,
                  "totalBytes": sum(item["bytes"] for item in results)}
    (root / "download-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps({"directory": str(root), "revision": REVISION,
                      "files": len(results), "totalBytes": provenance["totalBytes"]}))


if __name__ == "__main__":
    main()

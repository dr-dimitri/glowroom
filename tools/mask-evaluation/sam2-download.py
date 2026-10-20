#!/usr/bin/env python3
"""Download only pinned public SAM 2.1 Core ML files; never read test images."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

TINY_FILES = {
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
LARGE_FILES = {
    "ImageEncoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 528540, "b382195d0c3e2a93798f39e36085a71e66b1525ebd679d23a1bc8466361028b8"),
        ("Data/com.apple.CoreML/weights/weight.bin", 444351360, "a2908ac87bd862d756a4966c0ea9e710297bbc38b37b8c0243fc33dac5ff51d0"),
        ("Manifest.json", 617, "824ba98e9bf70d99139f69383284ca7a84b5666a5a54850b54a617c58fbecc63"),
    ),
    "MaskDecoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 75167, "71d343eb9464951bb6e7de6d8099c268b0dd2bdeb78e694e792b2562a5b55bea"),
        ("Data/com.apple.CoreML/weights/weight.bin", 10222400, "d7ccf6fc95e4fe21dba407f0d97a5859c1abce0c31edf1befb14714cfac58a7f"),
        ("Manifest.json", 617, "9b88413746456ef5e562dadd5676c3f2b391f51867ebd24c69e374033cbe094c"),
    ),
    "PromptEncoder": (
        ("Data/com.apple.CoreML/model.mlmodel", 20618, "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"),
        ("Data/com.apple.CoreML/weights/weight.bin", 2101056, "eadc79dd01eaf71001525a84bf835c8925d3a0463d1b34786bb6b734714fb0e7"),
        ("Manifest.json", 617, "babfa641ed5d14501a8036258561fe5fbcee90223f6045d92f64ca0d42e2e895"),
    ),
}
VARIANTS = {
    "tiny": {"revision": "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306", "name": "Tiny", "files": TINY_FILES},
    "large": {"revision": "e830c0874326be7ada2bdc9dff23b7073f884a83", "name": "Large", "files": LARGE_FILES},
}


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def download(entry):
    root, variant, config, verify_only, name, relative, size, expected = entry
    model_path = f"SAM2_1{config['name']}{name}FLOAT16.mlpackage/{relative}"
    repository = f"apple/coreml-sam2.1-{variant}"
    url = f"https://huggingface.co/{repository}/resolve/{config['revision']}/{model_path}"
    target = root / model_path
    if verify_only:
        actual_size = target.stat().st_size
        actual_hash = file_sha256(target)
        if actual_size != size or actual_hash != expected:
            raise ValueError(f"Integrity mismatch: {model_path}")
        return {"path": model_path, "bytes": actual_size, "sha256": actual_hash, "url": url}
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".download")
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
        actual_size = temporary.stat().st_size
        actual_hash = file_sha256(temporary)
        if actual_size != size or actual_hash != expected:
            raise ValueError(f"Integrity mismatch: {model_path}")
        temporary.replace(target)
        return {"path": model_path, "bytes": actual_size, "sha256": actual_hash, "url": url}
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_model_directory", type=Path)
    parser.add_argument("--variant", choices=VARIANTS, default="tiny")
    parser.add_argument("--verify-only", action="store_true", help="Verify existing files without network access")
    args = parser.parse_args()
    config = VARIANTS[args.variant]
    repository = f"apple/coreml-sam2.1-{args.variant}"
    root = args.output_model_directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    entries = [(root, args.variant, config, args.verify_only, name, path, size, digest) for name, files in config["files"].items()
               for path, size, digest in files]
    # Downloads are independent; three workers bound network and memory usage.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(download, entries))
    provenance = {"repository": repository, "revision": config["revision"], "variant": args.variant,
                  "license": "Apache-2.0", "files": results,
                  "totalBytes": sum(item["bytes"] for item in results)}
    if not args.verify_only:
        (root / "download-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps({"directory": str(root), "revision": config["revision"], "variant": args.variant,
                      "verifyOnly": args.verify_only,
                      "files": len(results), "totalBytes": provenance["totalBytes"]}))


if __name__ == "__main__":
    main()

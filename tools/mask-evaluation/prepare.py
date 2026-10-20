"""Prepare private, oriented sRGB proxies; never modify or upload originals."""
import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageOps


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    target_profile = ImageCms.createProfile("sRGB")
    manifest = []
    sheet = Image.new("RGB", (1400, 1200), "#202020")
    draw = ImageDraw.Draw(sheet)
    for index in range(1, 8):
        source = args.source / f"test_picture{index}.jpg"
        before = digest(source)
        with Image.open(source) as opened:
            dimensions = opened.size
            image = ImageOps.exif_transpose(opened)
            profile = opened.info.get("icc_profile")
            if profile:
                image = ImageCms.profileToProfile(
                    image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                    target_profile, outputMode="RGB")
            else:
                image = image.convert("RGB")
            image.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
            destination = args.output / f"test_picture{index}.png"
            # Fresh RGB raster strips camera EXIF and arbitrary source metadata.
            clean = Image.new("RGB", image.size)
            clean.paste(image)
            clean.save(destination)
            thumbnail = ImageOps.contain(clean, (450, 350))
            column, row = (index - 1) % 3, (index - 1) // 3
            sheet.paste(thumbnail, (column * 465, row * 400 + 25))
            draw.text((column * 465 + 8, row * 400 + 5),
                      f"test_picture{index} | {dimensions} -> {clean.size}", fill="white")
            manifest.append({"id": f"test_picture{index}", "sourceSHA256": before,
                             "sourceDimensions": dimensions, "proxyDimensions": clean.size,
                             "proxySHA256": digest(destination),
                             "sourceICC": bool(profile), "orientationApplied": True})
        if digest(source) != before:
            raise RuntimeError("Original changed during preparation")
    sheet.save(args.output.parent / "contact-sheet.jpg", quality=92)
    (args.output.parent / "private-input-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n")
    print(json.dumps([{k: v for k, v in item.items() if "SHA256" not in k}
                      for item in manifest], indent=2))


if __name__ == "__main__":
    main()

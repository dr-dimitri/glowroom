"""Local visual diagnostics; mask statistics are not accuracy scores."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps


def darken_background(image, mask, ev=-2):
    rgb = np.asarray(image, dtype=np.float32) / 255
    alpha = np.asarray(mask, dtype=np.float32)[..., None] / 255
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    linear *= alpha + (1 - alpha) * 2 ** ev
    result = np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.uint8(np.clip(result * 255 + 0.5, 0, 255)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--models", required=True, help="JSON mapping label to per-image mask glob")
    args = parser.parse_args()
    models = json.loads(args.models)
    destination = args.root / "visuals"
    destination.mkdir(exist_ok=True)
    statistics = []
    for index in range(1, 8):
        identity = f"test_picture{index}"
        with Image.open(args.root / "inputs" / (identity + ".png")) as opened:
            source = opened.convert("RGB")
        columns = 1 + len(models)
        sheet = Image.new("RGB", (columns * 400, 650), "#222222")
        draw = ImageDraw.Draw(sheet)
        sheet.paste(ImageOps.contain(source, (396, 290)), (0, 30))
        draw.text((8, 8), identity + " / source", fill="white")
        for column, (label, pattern) in enumerate(models.items(), 1):
            candidates = sorted(args.root.glob(pattern.replace("{id}", identity)))
            if not candidates:
                draw.text((column * 400 + 8, 8), label + " / missing", fill="white")
                continue
            path = candidates[0]
            with Image.open(path) as opened:
                mask = opened.convert("L")
            if mask.size != source.size:
                raise ValueError(f"Geometry mismatch: {label} / {identity}")
            alpha = np.asarray(mask)
            dark = darken_background(source, mask)
            sheet.paste(ImageOps.contain(mask.convert("RGB"), (396, 290)), (column * 400, 30))
            sheet.paste(ImageOps.contain(dark, (396, 290)), (column * 400, 350))
            draw.text((column * 400 + 8, 8), label + " / foreground mask", fill="white")
            draw.text((column * 400 + 8, 328), "background -2 EV (linear sRGB diagnostic)", fill="white")
            dark.save(destination / f"{identity}-{label}-background-minus2.png")
            statistics.append({"image": identity, "model": label,
                "minimum": int(alpha.min()), "maximum": int(alpha.max()),
                "foregroundFractionAtHalf": float(np.mean(alpha >= 128)),
                "fractionalCoverageFraction": float(np.mean((alpha > 0) & (alpha < 255))),
                "dimensions": list(mask.size)})
        sheet.save(destination / (identity + "-comparison.jpg"), quality=94)
    manifest = json.loads((args.root / "private-input-manifest.json").read_text())
    original_root = Path(__file__).resolve().parents[2] / "Fixtures" / "LocalTestImages"
    for item in manifest:
        source = original_root / (item["id"] + ".jpg")
        if hashlib.sha256(source.read_bytes()).hexdigest() != item["sourceSHA256"]:
            raise ValueError("Original image changed")
    (destination / "mask-statistics.json").write_text(json.dumps(statistics, indent=2) + "\n")
    print(json.dumps({"images": 7, "models": list(models), "originalsUnchanged": True}))


if __name__ == "__main__":
    main()

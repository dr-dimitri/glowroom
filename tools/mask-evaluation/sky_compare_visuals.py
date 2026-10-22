"""Private sky-mask diagnostics. Agreement and coverage are not accuracy scores."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps


def sky_adjustment(image, mask, ev=-3):
    rgb = np.asarray(image, dtype=np.float32) / 255
    alpha = np.asarray(mask, dtype=np.float32)[..., None] / 255
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    linear *= 1 - alpha + alpha * 2 ** ev
    srgb = np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.uint8(np.clip(srgb * 255 + 0.5, 0, 255)))


def load_mask(path, size):
    with Image.open(path) as opened:
        if opened.mode != "L" or opened.size != size:
            raise ValueError(f"Expected Gray8 mask with input geometry: {path}")
        return opened.copy()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def draw_panel(sheet, image, x, y, width, height):
    panel = ImageOps.contain(image.convert("RGB"), (width - 12, height - 12))
    sheet.paste(panel, (x + (width - panel.width) // 2, y + (height - panel.height) // 2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Contains inputs/ and private-input-manifest.json")
    parser.add_argument("output", type=Path, help="Must not exist")
    parser.add_argument("--originals", required=True, type=Path)
    parser.add_argument("--models", required=True, help="JSON label -> mask path relative to root, with {id}")
    parser.add_argument("--crops", type=Path, help="Optional private JSON id -> [left, top, right, bottom]")
    args = parser.parse_args()
    models = json.loads(args.models)
    if not isinstance(models, dict) or len(models) < 2:
        raise ValueError("Specify at least two model masks")
    manifest = json.loads((args.root / "private-input-manifest.json").read_text())
    crops = json.loads(args.crops.read_text()) if args.crops else {}
    prepared = []
    # Validate all paths before creating output; originals stay read-only.
    for item in manifest:
        identity = item["id"]
        original = args.originals / (identity + ".jpg")
        if digest(original) != item["sourceSHA256"]:
            raise ValueError(f"Original changed: {identity}")
        input_path = args.root / "inputs" / (identity + ".png")
        if digest(input_path) != item["proxySHA256"]:
            raise ValueError(f"Proxy changed: {identity}")
        with Image.open(input_path) as opened:
            source = opened.convert("RGB")
        masks = {label: load_mask(args.root / pattern.format(id=identity), source.size)
                 for label, pattern in models.items()}
        if identity in crops:
            left, top, right, bottom = crops[identity]
            if not 0 <= left < right <= source.width or not 0 <= top < bottom <= source.height:
                raise ValueError(f"Invalid crop: {identity}")
        prepared.append((identity, source, masks))
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    overview = Image.new("RGB", (450 * (len(models) + 1), 245 * len(prepared)), "#202020")
    overview_draw = ImageDraw.Draw(overview)
    for row, (identity, source, masks) in enumerate(prepared):
        columns = 1 + len(masks)
        sheet = Image.new("RGB", (600 * columns, 1240), "#202020")
        draw = ImageDraw.Draw(sheet)
        draw.text((12, 10), identity + " / original", fill="white")
        draw_panel(sheet, source, 0, 35, 600, 390)
        draw.text((12, 435), "Gray8: white = selected sky", fill="white")
        draw.text((12, 845), "Sky -3 EV in linear sRGB; diagnostic, not app renderer", fill="white")
        draw_panel(overview, source, 0, row * 245 + 25, 450, 220)
        overview_draw.text((12, row * 245 + 7), identity + " / original", fill="white")
        stats = {}
        binaries = []
        for column, (label, mask) in enumerate(masks.items(), 1):
            alpha = np.asarray(mask)
            adjusted = sky_adjustment(source, mask)
            draw.text((600 * column + 12, 10), label, fill="white")
            rgb = np.asarray(source, dtype=np.float32)
            overlay = rgb * (1 - alpha[..., None] / 255 * 0.45)
            overlay[..., 0] += alpha / 255 * 0.45 * 255
            draw_panel(sheet, Image.fromarray(np.uint8(np.clip(overlay, 0, 255))), column * 600, 35, 600, 390)
            draw_panel(sheet, mask, column * 600, 445, 600, 390)
            draw_panel(sheet, adjusted, column * 600, 855, 600, 380)
            draw_panel(overview, adjusted, column * 450, row * 245 + 25, 450, 220)
            overview_draw.text((column * 450 + 12, row * 245 + 7), label + " / sky -3 EV", fill="white")
            stats[label] = {"selectedFractionAtHalf": float(np.mean(alpha >= 128)),
                            "meanCoverage": float(np.mean(alpha) / 255),
                            "fractionalPixelFraction": float(np.mean((alpha > 0) & (alpha < 255)))}
            binaries.append(alpha >= 128)
            adjusted.save(args.output / f"{identity}-{column}-sky-minus3.png")
        union = np.logical_or(binaries[0], binaries[1]).sum()
        records.append({"id": identity, "models": stats,
                        "firstTwoMaskAgreementIoUAtHalf": float(np.logical_and(binaries[0], binaries[1]).sum() / union) if union else None,
                        "firstTwoDisagreementFractionAtHalf": float(np.mean(binaries[0] != binaries[1]))})
        sheet.save(args.output / f"{identity}-comparison.jpg", quality=95)
        if identity in crops:
            box = tuple(crops[identity])
            left, top, right, bottom = box
            crop_sheet = Image.new("RGB", ((right - left) * columns, (bottom - top) * 2 + 50), "#202020")
            crop_draw = ImageDraw.Draw(crop_sheet)
            crop_sheet.paste(source.crop(box), (0, 50))
            crop_draw.text((10, 10), identity + " / 100% crop", fill="white")
            for column, (label, mask) in enumerate(masks.items(), 1):
                x = column * (right - left)
                crop_draw.text((x + 10, 10), label, fill="white")
                crop_sheet.paste(sky_adjustment(source, mask).crop(box), (x, 50))
                crop_sheet.paste(mask.crop(box).convert("RGB"), (x, 50 + bottom - top))
            crop_sheet.save(args.output / f"{identity}-crop.png")
    overview.save(args.output / "overview.jpg", quality=95)
    (args.output / "statistics.json").write_text(json.dumps({"scope": "Visual diagnostics; no ground truth; model agreement is not accuracy.", "records": records}, indent=2) + "\n")
    print(json.dumps({"images": len(prepared), "models": list(models), "originalsUnchanged": True}))


if __name__ == "__main__":
    main()

"""Original procedural fixtures. No external images, text, private data, or ML.

Canonical convention: top-left coordinates, 8-bit sRGB RGB/RGBA, L8 replacement
mask (255 replaces), final compositor retains source RGBA where mask == 0.
The full manifest is frozen before any real model inference.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import hashlib
import json
import math

ROOT = Path(__file__).parent
OUT = ROOT / "fixtures"
OUT.mkdir(exist_ok=True)


def panel(size=(512, 512)):
    im = Image.new("RGB", size)
    pix = im.load()
    for y in range(size[1]):
        for x in range(size[0]):
            # Integer, deterministic structured background, no random state.
            grain = ((x * 17 + y * 3) % 19) - 9
            board = -23 if y % 64 in (0, 1, 62, 63) else 0
            pix[x, y] = (max(0, 174 + grain + board), max(0, 145 + grain + board), max(0, 110 + grain + board))
    return im


def mask(size):
    return Image.new("L", size, 0)


def record(name, source, masks, prompt, expected, extra=None):
    src = OUT / f"{name}-source.png"
    source.save(src, compress_level=9)
    item = {
        "id": name,
        "source": str(src.relative_to(ROOT)),
        "size": list(source.size),
        "mode": source.mode,
        "prompt": prompt,
        "negativePrompt": "blurry, distorted, new objects, text, watermark",
        "parameters": {"steps": 25, "cfgScale": 7.5, "strength": 1.0, "seed": 4281, "sampler": "euler", "scheduler": "discrete", "batchCount": 1},
        "expectation": expected,
        "masks": [],
        "sourcePixelSHA256": hashlib.sha256(source.tobytes()).hexdigest(),
        "sourceFileSHA256": hashlib.sha256(src.read_bytes()).hexdigest(),
    }
    for label, m in masks:
        p = OUT / f"{name}-mask-{label}.png"
        m.save(p, compress_level=9)
        item["masks"].append({"kind": label, "path": str(p.relative_to(ROOT)), "pixelSHA256": hashlib.sha256(m.tobytes()).hexdigest(), "fileSHA256": hashlib.sha256(p.read_bytes()).hexdigest(), "replacementPixels": sum(v > 0 for v in m.tobytes())})
    if extra:
        item.update(extra)
    return item


items = []

# 1: object removal over structured texture.
im = panel(); d = ImageDraw.Draw(im)
d.ellipse((194, 180, 318, 304), fill=(201, 30, 40), outline=(80, 15, 20), width=4)
d.ellipse((212, 194, 239, 221), fill=(243, 115, 105))
m = mask(im.size); ImageDraw.Draw(m).ellipse((181, 167, 331, 317), fill=255)
items.append(record("01-structured-removal", im, [("hard", m)], "an empty wooden panel, continuous horizontal wood boards, natural wood texture", "The red ball disappears. Horizontal panel lines continue naturally through the replacement; no new object, halo, or seam."))

# 2: mask touches the right edge. Off-center geometry catches mirror/flip errors.
im = panel(); d = ImageDraw.Draw(im)
d.rounded_rectangle((423, 269, 538, 412), radius=17, fill=(29, 78, 196), outline=(12, 36, 99), width=5)
d.ellipse((405, 292, 449, 362), outline=(22, 62, 165), width=10)
m = mask(im.size); ImageDraw.Draw(m).rectangle((391, 253, 511, 430), fill=255)
items.append(record("02-edge-object", im, [("hard", m)], "an empty wooden panel, continuous horizontal wood boards, natural wood texture", "The edge cup disappears; no inward displacement, mirrored mask, edge smear, or invented new object."))

# 3: identical source and prompt, explicitly compare binary and feathered edges.
im = panel(); d = ImageDraw.Draw(im)
d.rectangle((115, 248, 246, 361), fill=(239, 184, 35), outline=(107, 72, 12), width=4)
m = mask(im.size); ImageDraw.Draw(m).rectangle((97, 230, 264, 379), fill=255)
soft = m.filter(ImageFilter.GaussianBlur(radius=5))
items.append(record("03-mask-edge", im, [("hard", m), ("soft", soft)], "an empty wooden panel, continuous horizontal wood boards, natural wood texture", "Both masks remove the yellow block. The feathered final composite has no visible bright/dark border. Hard and soft masks use the same source and seed."))

# 4: semi-transparent source with nonuniform alpha; compositor must retain it.
im = panel().convert("RGBA"); px = im.load()
for y in range(512):
    for x in range(512):
        r, g, b, _ = px[x, y]
        px[x, y] = (r, g, b, 72 + (x * 151 // 511))
d = ImageDraw.Draw(im)
d.ellipse((292, 109, 378, 195), fill=(177, 34, 178, 160), outline=(77, 20, 88, 180), width=3)
m = mask(im.size); ImageDraw.Draw(m).ellipse((276, 93, 394, 211), fill=255)
items.append(record("04-partial-alpha", im, [("hard", m)], "an empty wooden panel, continuous horizontal wood boards, natural wood texture", "Purple disk disappears in RGB. Source alpha is preserved by the declared source-alpha policy, including every alpha byte outside the composite mask.", {"alphaPolicy": "preserve-source-alpha; inference receives explicit white-matted RGB"}))

# 5: thin foreground motif must survive background replacement.
im = panel(); d = ImageDraw.Draw(im)
d.rectangle((172, 64, 355, 183), fill=(25, 110, 199), outline=(9, 43, 84), width=3)
keep = mask(im.size); k = ImageDraw.Draw(keep)
for dx in range(-3, 4):
    k.line((248 + dx, 468, 260 + dx, 40), fill=255, width=1)
for y in range(95, 441, 31):
    k.line((256, y, 170, y - 54), fill=255, width=3)
    k.line((256, y, 341, y - 48), fill=255, width=3)
im.paste((27, 81, 34), (0, 0, 512, 512), keep)
m = Image.eval(keep, lambda x: 255 - x)
items.append(record("05-fine-motif-edges", im, [("hard", m)], "a plain warm beige wall, smooth plaster texture, empty background", "The protected thin green stem and every leaf line remain exact. Background becomes a beige wall with no new outline, halo, or border at fine edges.", {"capability": "background-with-preserve-mask"}))

# 6: non-square canvas; original source is anchored without distortion/resizing.
original = panel((384, 256)); d = ImageDraw.Draw(original)
d.rectangle((51, 79, 103, 147), fill=(35, 108, 191), outline=(15, 39, 82), width=3)
canvas = Image.new("RGB", (640, 384), (127, 127, 127))
canvas.paste(original, (128, 64))
m = Image.new("L", canvas.size, 255)
ImageDraw.Draw(m).rectangle((128, 64, 511, 319), fill=0)
original_path = OUT / "06-canvas-original.png"; original.save(original_path, compress_level=9)
items.append(record("06-nonsquare-canvas", canvas, [("hard", m)], "continuous horizontal wood panel boards extending naturally, natural wood texture", "Only the padded canvas is generated. The original 384 by 256 source stays at x128/y64 with exact RGB bytes and unchanged proportions. Board lines extend beyond all four edges without a visible seam.", {"capability": "outpaint-by-pad-and-inpaint", "original": str(original_path.relative_to(ROOT)), "originalPixelSHA256": hashlib.sha256(original.tobytes()).hexdigest(), "sourcePlacement": {"x": 128, "y": 64, "width": 384, "height": 256}, "transform": "integer translation only; no resize, crop, flip, or rotation"}))

manifest = {"schemaVersion": 1, "fixtureVersion": "picedit-inpainting-gate-v1", "creator": "Original deterministic procedural code in create-fixtures.py", "fixtureCount": 6, "maskConvention": "L8 255 replacement; 0 preservation; source top-left orientation", "generationMaskPolicy": "binary >=128; final compositor retains original soft mask", "colorSpace": "sRGB canonical values; orientation up", "fixtures": items}
p = ROOT / "fixtures-manifest.json"
p.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
h = hashlib.sha256(p.read_bytes()).hexdigest()
(ROOT / "fixtures-manifest.sha256").write_text(h + "  fixtures-manifest.json\n")
print(h)


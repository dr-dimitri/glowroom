"""Reproduce the fixed, photo-free input matrix; no random inputs or models."""
import json
import math
from pathlib import Path
from reference import BANDS, CENTERS, decode_srgb, hsv_rgb, to_rgb


def fixtures():
    result = []
    def add(name, group, rgb, alpha=1):
        result.append({"id": name, "group": group, "rgba": list(rgb) + [alpha]})
    for i, value in enumerate((-.25, 0, .003, .01, .05, .18, .5, 1, 2, 4, 16, 64, 256, 1024)):
        for alpha in (0, .25, 1):
            add(f"gray-{i}-{alpha}", "gray", (value,) * 3, alpha)
    for i in range(4097):
        add(f"circle-{i}", "circle", tuple(decode_srgb(x) for x in hsv_rgb(i * 360 / 4096)))
    # Display P3 primaries, secondaries and extended linear combinations,
    # transformed by a fixed D65 linear Display P3 -> extended-linear-sRGB
    # matrix. Negative values intentionally remain outside the sRGB cube.
    p3_to_srgb = ((1.2249401763, -.2249401763, 0),
                  (-.0420569547, 1.0420569547, 0),
                  (-.0196375546, -.0786360456, 1.0982736002))
    p3 = ((1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0),
          (1, 0, 1), (0, 1, 1), (.8, .05, .1), (.05, .8, .1), (.1, .05, .8))
    for i, sample in enumerate(p3):
        rgb = tuple(sum(a * b for a, b in zip(row, sample)) for row in p3_to_srgb)
        for alpha in (.25, 1):
            add(f"p3-{i}-{alpha}", "p3", rgb, alpha)
    for exponent in (1, 2, 4, 6, 8, 10):
        scale = 2**exponent
        for i, degrees in enumerate((0, 30, 60, 120, 180, 225, 270, 315)):
            base = tuple(decode_srgb(x) for x in hsv_rgb(degrees))
            for alpha in (.25, 1):
                add(f"hdr-{exponent}-{i}-{alpha}", "hdr", tuple(x * scale for x in base), alpha)
    for i, center in enumerate(CENTERS):
        for side, offset in (("left", -1e-7), ("at", 0), ("right", 1e-7)):
            h = center + offset
            add(f"boundary-{i}-{side}", "boundary", to_rgb((.65, .12 * math.cos(h), .12 * math.sin(h))))
    # Synthetic representative swatches complement numeric ramps; their names
    # identify intended content, not measured natural-photo color appearance.
    for name, rgb in (("skin", (.55, .28, .16)), ("sky", (.12, .3, .75)),
                      ("vegetation", (.08, .35, .04)), ("orange", (1, decode_srgb(.5), 0)),
                      ("negative-lms", (-.6, .1, .01)), ("near-lms-zero", (-.1, .076861, 0))):
        for alpha in (0, .25, 1):
            add(f"patch-{name}-{alpha}", "patch", rgb, alpha)
    return result


def document():
    moderate = {"blue": {"hue": 15, "saturation": -25, "lightness": -20}}
    mixed = {name: {"hue": [12, -10, 5, 15, -12, 8, -9, 10][i],
                     "saturation": [10, -15, 20, 15, -20, -25, 10, 20][i],
                     "lightness": [-10, 15, -12, 10, 12, -20, 15, -10][i]}
             for i, name in enumerate(BANDS)}
    return {"version": 1, "fixtures": fixtures(), "settings": [
        {"id": "neutral", "kind": "neutral", "value": {"version": 1, "bands": {}}},
        {"id": "blue-moderate", "kind": "moderate", "value": {"version": 1, "bands": moderate}},
        {"id": "mixed-moderate", "kind": "moderate", "value": {"version": 1, "bands": mixed}},
        *({"id": f"extreme-{sign}", "kind": "extreme", "value": {"version": 1, "bands": {
            band: {"hue": 100 * sign, "saturation": 100 * sign, "lightness": 100 * sign}
            for band in BANDS}}} for sign in (-1, 1))]}


if __name__ == "__main__":
    Path(__file__).with_name("fixtures.json").write_text(json.dumps(document(), indent=2, allow_nan=False) + "\n")

"""Independent scalar oracle for the unqualified LC2 eight-band candidate v1.

Double arithmetic, generic matrices, and bisected circular intervals are
deliberately separate from the Float Core Image implementation. No third-party
Python packages, photographs, app models, or image quantization are required.
"""
import bisect
import math
import struct

VERSIONS = (1, 2)
BANDS = ("red", "orange", "yellow", "green", "aqua", "blue", "violet", "magenta")
HSV_DEGREES = (0, 30, 60, 120, 180, 225, 270, 315)
RGB_TO_LMS = (
    (.4122214708, .5363325363, .0514459929),
    (.2119034982, .6806995451, .1073969566),
    (.0883024619, .2817188376, .6299787005),
)
LMS_ROOT_TO_LAB = (
    (.2104542553, .7936177850, -.0040720468),
    (1.9779984951, -2.4285922050, .4505937099),
    (.0259040371, .7827717662, -.8086757660),
)
LAB_TO_LMS_ROOT = (
    (1, .3963377774, .2158037573),
    (1, -.1055613458, -.0638541728),
    (1, -.0894841775, -1.2914855480),
)
LMS_TO_RGB = (
    (4.0767416621, -3.3077115913, .2309699292),
    (-1.2684380046, 2.6097574011, -.3413193965),
    (-.0041960863, -.7034186147, 1.7076147010),
)


def matrix(rows, vector):
    return tuple(sum(coefficient * value for coefficient, value in zip(row, vector)) for row in rows)


def to_lab(rgb):
    return matrix(LMS_ROOT_TO_LAB, tuple(math.cbrt(x) for x in matrix(RGB_TO_LMS, rgb)))


def to_rgb(lab):
    return matrix(LMS_TO_RGB, tuple(x**3 for x in matrix(LAB_TO_LMS_ROOT, lab)))


def decode_srgb(x):
    return math.copysign(abs(x) / 12.92 if abs(x) <= .04045 else ((abs(x) + .055) / 1.055)**2.4, x)


def hsv_rgb(degrees):
    """sRGB-coded HSV(H, 1, 1); HSV is used only to define band centers."""
    phase = (degrees % 360) / 60
    sector, amount = int(phase), phase % 1
    return ((1, amount, 0), (1 - amount, 1, 0), (0, 1, amount),
            (0, 1 - amount, 1), (amount, 0, 1), (1, 0, 1 - amount))[sector]


def center(degrees):
    _, a, b = to_lab(tuple(decode_srgb(x) for x in hsv_rgb(degrees)))
    return math.atan2(b, a) % math.tau


CENTERS = tuple(center(h) for h in HSV_DEGREES)
assert list(CENTERS) == sorted(CENTERS)


def weights(hue):
    """Two adjacent raised-cosine weights form a circular partition of unity."""
    hue %= math.tau
    right = bisect.bisect_right(CENTERS, hue)
    left = (right - 1) % 8
    right %= 8
    start = CENTERS[left]
    end = CENTERS[right] + (math.tau if right == 0 else 0)
    if hue < start:
        hue += math.tau
    fraction = (hue - start) / (end - start)
    rising = (1 - math.cos(math.pi * fraction)) / 2
    result = [0.] * 8
    result[left], result[right] = 1 - rising, rising
    return tuple(result)


def validate(settings):
    if set(settings) != {"version", "bands"} or type(settings["version"]) is not int or settings["version"] not in VERSIONS:
        raise ValueError("unknown color-mixer candidate version or fields")
    bands = settings["bands"]
    if not isinstance(bands, dict) or set(bands) - set(BANDS):
        raise ValueError("unknown bands")
    for values in bands.values():
        if set(values) != {"hue", "saturation", "lightness"}:
            raise ValueError("each present band requires three parameters")
        if not all(type(x) in (int, float) and math.isfinite(x) and -100 <= x <= 100 for x in values.values()):
            raise ValueError("invalid parameter")
        if not any(values.values()):
            raise ValueError("neutral bands must be omitted")
    return settings


def apply(rgb, settings):
    validate(settings)
    if not all(math.isfinite(x) for x in rgb):
        raise ValueError("nonfinite RGB")
    # The exact gray axis and the globally neutral candidate are true no-ops.
    # This avoids manufacturing chroma from rounded conversion coefficients.
    if not settings["bands"] or rgb[0] == rgb[1] == rgb[2]:
        return tuple(rgb)
    lightness, a, b = to_lab(rgb)
    chroma = math.hypot(a, b)
    if chroma == 0:
        return tuple(rgb)
    hue = math.atan2(b, a) % math.tau
    w = weights(hue)
    shifts = [sum(w[i] * settings["bands"].get(band, {}).get(key, 0) / 100
                  for i, band in enumerate(BANDS)) for key in ("hue", "saturation", "lightness")]
    if not any(shifts):
        return tuple(rgb)
    damping = min(chroma / .12, 1)
    new_hue = hue + .5 * shifts[0] * damping
    new_chroma = max(0, chroma * (1 + shifts[1]))
    new_lightness = lightness + .2 * shifts[2] * damping * math.sqrt(max(lightness, .05))
    new_lab = (new_lightness, new_chroma * math.cos(new_hue), new_chroma * math.sin(new_hue))
    output = to_rgb(new_lab)
    if settings["version"] == 1:
        return output
    # Explicitly versioned alternative: preserve the original RGB as the base
    # and add only the inverse-OkLab color difference. Rounded forward/inverse
    # matrices need no longer reproduce an unchanged full HDR baseline.
    baseline = to_rgb((lightness, a, b))
    return tuple(source + after - before for source, after, before in zip(rgb, output, baseline))


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def input_pixel(rgba):
    """The exact native premultiplied RGBAf input, represented as Doubles."""
    alpha = f32(rgba[3])
    return tuple(f32(f32(x) * alpha) for x in rgba[:3]) + (alpha,)


def reference_pixel(rgba, settings):
    rgba = input_pixel(rgba)
    alpha = rgba[3]
    if alpha == 0:
        return (0., 0., 0., 0.)
    straight = tuple(x / alpha for x in rgba[:3])
    return apply(straight, settings) + (alpha,)

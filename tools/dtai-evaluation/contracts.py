"""Independently written research contracts; never imported by the app.

No upstream implementation is imported. Small deterministic coordinate and gate
operations stay serial: scheduling overhead exceeds their work. Native inference
also stays serial, with one retained lease/session per synchronous CLI process.
"""
from dataclasses import asdict, dataclass
import hashlib
import json
import math

REVISION = "76513a1e379b4265007bae768825b9a581944ff8"
GEOMETRY_VERSION = "segnext-edge-coordinates-v1"


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


@dataclass(frozen=True)
class PromptFrame:
    """Original edge coordinates -> EXIF -> crop -> clockwise turns -> 1024.

    Coordinates use continuous pixel edges, pixel centres are i+0.5. Crop is in
    the oriented raster. Preview coordinates use the same edge convention; a
    resize changes scale only. Rotation is deliberately limited to quarter turns;
    arbitrary editor rotations require a separately qualified affine contract.
    """
    source_sha256: str
    width: int
    height: int
    exif_orientation: int = 1
    crop: tuple | None = None
    turns: int = 0

    def __post_init__(self):
        if len(self.source_sha256) != 64 or any(c not in "0123456789abcdef" for c in self.source_sha256):
            raise ValueError("source SHA-256 required")
        if type(self.width) is not int or type(self.height) is not int or min(self.width, self.height) < 1:
            raise ValueError("positive integer raster dimensions required")
        if self.exif_orientation not in range(1, 9) or self.turns not in range(4):
            raise ValueError("unsupported orientation/rotation")
        x, y, w, h = self.bounds
        ow, oh = self.oriented_size
        if not all(finite(v) for v in (x, y, w, h)) or x < 0 or y < 0 or min(w, h) <= 0 or x+w > ow or y+h > oh:
            raise ValueError("crop must lie inside oriented raster")

    @property
    def oriented_size(self):
        return (self.height, self.width) if self.exif_orientation >= 5 else (self.width, self.height)

    @property
    def bounds(self):
        return self.crop if self.crop is not None else (0, 0, *self.oriented_size)

    @property
    def frame_size(self):
        _, _, w, h = self.bounds
        return (h, w) if self.turns % 2 else (w, h)

    @property
    def identity(self):
        return digest_json({"version": GEOMETRY_VERSION, **asdict(self)})

    def _orient(self, x, y):
        w, h = self.width, self.height
        return {1:(x,y), 2:(w-x,y), 3:(w-x,h-y), 4:(x,h-y),
                5:(y,x), 6:(h-y,x), 7:(h-y,w-x), 8:(y,w-x)}[self.exif_orientation]

    def _unorient(self, x, y):
        w, h = self.width, self.height
        return {1:(x,y), 2:(w-x,y), 3:(w-x,h-y), 4:(x,h-y),
                5:(y,x), 6:(y,h-x), 7:(w-y,h-x), 8:(w-y,x)}[self.exif_orientation]

    def to_prompt(self, point, *, source_sha256, frame_id):
        if source_sha256 != self.source_sha256 or frame_id != self.identity:
            raise ValueError("point belongs to another source/preparation")
        x, y = point
        if not all(finite(v) for v in point) or not (0 <= x < self.width and 0 <= y < self.height):
            raise ValueError("point outside original raster")
        x, y = self._orient(x, y)
        cx, cy, w, h = self.bounds
        x, y = x-cx, y-cy
        if not (0 <= x < w and 0 <= y < h):
            raise ValueError("point outside crop")
        x, y = [(x,y), (h-y,x), (w-x,h-y), (y,w-x)][self.turns]
        fw, fh = self.frame_size
        px, py = x*1024/fw, y*1024/fh
        if not (0 <= px < 1024 and 0 <= py < 1024):
            raise ValueError("point lies on excluded transformed edge")
        return px, py

    def from_prompt(self, point):
        px, py = point
        if not all(finite(v) for v in point) or not (0 <= px < 1024 and 0 <= py < 1024):
            raise ValueError("point outside prompt frame")
        fw, fh = self.frame_size
        x, y = px*fw/1024, py*fh/1024
        cx, cy, w, h = self.bounds
        x, y = [(x,y), (y,h-x), (w-x,h-y), (w-y,x)][self.turns]
        return self._unorient(x+cx, y+cy)

    def preview_to_original(self, point, preview_size):
        pw, ph = preview_size
        if not all(finite(v) and v > 0 for v in (pw, ph)):
            raise ValueError("invalid preview size")
        x, y = point
        return self.from_prompt((x*1024/pw, y*1024/ph))


def segnext_gate(cases):
    """Quality-only computation. It cannot grant product/native qualification."""
    if len(cases) != 12 or len({c["id"] for c in cases}) != 12:
        raise ValueError("exactly twelve unique frozen cases required")
    details = []
    for case in cases:
        start, clicks, parity = case["start_iou"], case["click_ious"], case["native_reference_iou"]
        values = [start, parity, *clicks]
        if not 1 <= len(clicks) <= 10 or not all(finite(v) and 0 <= v <= 1 for v in values):
            raise ValueError("finite IoUs and one to ten correction clicks required")
        # A start already meeting the target needs zero correction clicks.
        noc = 0 if start >= .85 else next((i+1 for i,v in enumerate(clicks) if v >= .85), 11)
        details.append({"id": case["id"], "start_iou": start, "click_ious": clicks,
                        "noc85": noc, "reached85": noc != 11,
                        "native_reference_iou": parity, "improvement": clicks[-1]-start})
    failures = []
    within5 = sum(c["noc85"] <= 5 for c in details)
    improvement = sum(c["improvement"] for c in details)/12
    if within5 < 10:
        failures.append("fewer than ten of twelve reach .85 in at most five clicks")
    if improvement < .05 - 1e-12:
        failures.append("mean final IoU improvement below .05")
    if any(c["native_reference_iou"] < .99 - 1e-12 for c in details):
        failures.append("native/reference final binary-mask disagreement above .01 IoU")
    return {"quality": "no-go" if failures else "quality-pass-unqualified", "failures": failures,
            "cases": details, "within_five": within5, "mean_improvement": improvement,
            "unreached": sum(not c["reached85"] for c in details),
            "bounded_mean_noc85": sum(c["noc85"] for c in details)/12}

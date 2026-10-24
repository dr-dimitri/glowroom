"""Local FP32 research adapters, not a Glowroom runtime or model converter.

Inputs are explicit NumPy tensors, not image filenames: this cannot accidentally
re-decode RAWs or silently resize/quantise an export. Models execute on ONNX CPU
only; Core ML/ANE/GPU support needs its own parity and resource qualification.
"""
from collections import OrderedDict
from dataclasses import dataclass, field
import hashlib
import io
import math
import os
import time

SNAPSHOT_BUDGET = 1024*1024*1024


@dataclass(frozen=True)
class FileSnapshot:
    """The digest and every decoder consume these identical immutable bytes."""
    data: bytes
    digest: str = field(init=False)

    def __post_init__(self):
        if type(self.data) is not bytes or len(self.data) > SNAPSHOT_BUDGET:
            raise ValueError("immutable bytes within the 1 GiB snapshot budget required")
        object.__setattr__(self,"digest",hashlib.sha256(self.data).hexdigest())

    @classmethod
    def read(cls, path, remaining=SNAPSHOT_BUDGET):
        with open(path,"rb") as stream:
            size = os.fstat(stream.fileno()).st_size
            if size > remaining:
                raise ValueError("combined immutable-file snapshot budget exceeds 1 GiB")
            data = stream.read(size+1)
            if len(data) != size:
                raise ValueError("file size changed while making immutable snapshot")
        return cls(data)


def load_npy(snapshot, max_array_bytes=512*1024*1024):
    if not isinstance(snapshot,FileSnapshot):
        raise ValueError("immutable NPY snapshot required")
    np = numpy()
    stream = io.BytesIO(snapshot.data)
    version = np.lib.format.read_magic(stream)
    if version == (1,0):
        shape,_,dtype = np.lib.format.read_array_header_1_0(stream)
    elif version == (2,0):
        shape,_,dtype = np.lib.format.read_array_header_2_0(stream)
    else:
        raise ValueError("only explicit NPY v1/v2 FP32 tensor storage supported")
    if dtype != np.dtype(np.float32) or len(shape) != 4 or any(type(n) is not int or n < 1 for n in shape):
        raise ValueError("FP32 rank-four tensor header required")
    expected = math.prod(shape)*4
    if expected > max_array_bytes or stream.tell()+expected != len(snapshot.data):
        raise ValueError("NPY payload size differs from header or exceeds tensor budget")
    return np.load(io.BytesIO(snapshot.data),allow_pickle=False)


def reject_external_data(model_bytes):
    """Inspect every protobuf submessage, including nested graphs/sparse tensors.

    Model bytes never get a base directory. No sidecar can be resolved by this
    adapter, and declaring any ONNX external tensor storage fails before ORT.
    """
    try:
        import onnx
    except ImportError as error:
        raise ValueError("pinned onnx required to reject external tensor sidecars") from error
    model = onnx.load_model_from_string(model_bytes)
    pending = [model]
    while pending:
        message = pending.pop()
        if message.DESCRIPTOR.full_name == "onnx.TensorProto":
            if message.data_location == onnx.TensorProto.EXTERNAL or len(message.external_data):
                raise ValueError("ONNX ExternalData sidecars are not supported; inline weights required")
        for descriptor,value in message.ListFields():
            if descriptor.message_type is not None:
                if descriptor.is_repeated:
                    pending.extend(value)
                else:
                    pending.append(value)


def sha256(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024*1024), b""):
            result.update(block)
    return result.hexdigest()


def numpy():
    try:
        import numpy as np
    except ImportError as error:
        raise ValueError("install the pinned research requirements in an isolated environment") from error
    return np


def tensor(value, channels, *, shape=None, unit_range=False):
    np = numpy()
    if not isinstance(value, np.ndarray) or value.dtype != np.float32:
        raise ValueError("FP32 ndarray required; implicit precision conversions forbidden")
    if value.ndim != 4 or value.shape[:2] != (1, channels) or min(value.shape[2:]) < 1:
        raise ValueError(f"expected [1,{channels},H,W]")
    if shape and value.shape != shape:
        raise ValueError(f"expected static shape {shape}, got {value.shape}")
    if not np.isfinite(value).all():
        raise ValueError("nonfinite tensor")
    if unit_range and (value.min() < 0 or value.max() > 1):
        raise ValueError("SDR [0,1] input required; HDR/negative RGB is unqualified")
    return value


def transfer(value, *, to_encoded):
    """Straight SDR linear sRGB <-> encoded sRGB. Never clip HDR/wide-gamut."""
    np = numpy()
    tensor(value, 3, unit_range=True)
    if to_encoded:
        return np.where(value <= .0031308, value*12.92,
                        1.055*np.power(value, 1/2.4)-.055).astype(np.float32)
    return np.where(value <= .04045, value/12.92,
                    np.power((value+.055)/1.055, 2.4)).astype(np.float32)


def prepare_segnext(image, frame):
    """Prepare an existing decoded SDR basis, with the PromptFrame geometry.

    Float-channel Lanczos resizing avoids a hidden uint8 round-trip. Its
    numerical parity with the upstream uint8/Pillow reference is unqualified;
    a future photo gate must compare this preparation as well as the model.
    Lanczos overshoot is explicitly bounded to the encoder's SDR domain.
    """
    np = numpy()
    try:
        from PIL import Image
    except ImportError as error:
        raise ValueError("pinned Pillow required for SegNext preparation") from error
    tensor(image,3,shape=(1,3,frame.height,frame.width),unit_range=True)
    # The continuous-edge PromptFrame and these discrete raster operations
    # share the same EXIF mapping; tests track individual pixel centres.
    raster = image[0]
    orientation = frame.exif_orientation
    if orientation == 2:
        raster = raster[:,:,::-1]
    elif orientation == 3:
        raster = raster[:,::-1,::-1]
    elif orientation == 4:
        raster = raster[:,::-1,:]
    elif orientation == 5:
        raster = raster.transpose(0,2,1)
    elif orientation == 6:
        raster = np.rot90(raster,-1,axes=(1,2))
    elif orientation == 7:
        raster = raster.transpose(0,2,1)[:,::-1,::-1]
    elif orientation == 8:
        raster = np.rot90(raster,1,axes=(1,2))
    x,y,w,h = frame.bounds
    if any(int(v) != v for v in (x,y,w,h)):
        raise ValueError("fractional crop needs a separately qualified resampler")
    x,y,w,h = map(int,(x,y,w,h))
    raster = np.rot90(raster[:,y:y+h,x:x+w],-frame.turns,axes=(1,2))
    result = np.stack([np.asarray(Image.fromarray(np.ascontiguousarray(channel)).resize((1024,1024),Image.Resampling.LANCZOS),dtype=np.float32) for channel in raster])[None]
    return np.clip(result,0,1).astype(np.float32)


def project_segnext(logits, frame):
    """Reference order: logits>0 -> uint8 Lanczos resize -> >127 -> inverse geometry.

    Outside the evaluated crop the proposal is zero. This is a binary object
    proposal, never a replacement alpha matte. No accepted mask is mutated.
    """
    np = numpy()
    from PIL import Image
    tensor(logits,1,shape=(1,1,1024,1024))
    x,y,w,h = frame.bounds
    if any(int(v) != v for v in (x,y,w,h)):
        raise ValueError("fractional crop needs a separately qualified resampler")
    x,y,w,h = map(int,(x,y,w,h))
    fw,fh = map(int,frame.frame_size)
    resized = np.asarray(Image.fromarray((logits[0,0] > 0).astype(np.uint8)*255).resize((fw,fh),Image.Resampling.LANCZOS)) > 127
    crop = np.rot90(resized,frame.turns)
    ow,oh = frame.oriented_size
    raster = np.zeros((oh,ow),dtype=bool)
    raster[y:y+h,x:x+w] = crop
    orientation = frame.exif_orientation
    if orientation == 2:
        raster = raster[:,::-1]
    elif orientation == 3:
        raster = raster[::-1,::-1]
    elif orientation == 4:
        raster = raster[::-1,:]
    elif orientation == 5:
        raster = raster.T
    elif orientation == 6:
        raster = np.rot90(raster,1)
    elif orientation == 7:
        raster = raster.T[::-1,::-1]
    elif orientation == 8:
        raster = np.rot90(raster,-1)
    return raster[None,None].astype(np.float32)


def binary_iou(predicted, truth):
    np = numpy()
    if predicted.shape != truth.shape or predicted.size == 0:
        raise ValueError("equally shaped nonempty binary masks required")
    for value in (predicted,truth):
        if not np.isin(value,(0,1)).all():
            raise ValueError("binary masks required; alpha coverage is not binary GT")
    union = np.logical_or(predicted,truth).sum()
    return float(np.logical_and(predicted,truth).sum()/union) if union else 1.0


def mirror_indices(start, count, length):
    """Reflect about boundary pixel centres; singleton axes repeat safely."""
    np = numpy()
    if length < 1:
        raise ValueError("empty axis")
    if length == 1:
        return np.zeros(count, dtype=np.int64)
    period = 2*(length-1)
    folded = np.arange(start, start+count, dtype=np.int64) % period
    return np.minimum(folded, period-folded)


def tiled(arr, infer, *, tile_size=768, overlap=64, scale=1, output_channels=3,
          max_tensor_bytes=512*1024*1024, cancelled=lambda: False):
    """One tile at a time, mirrored halo, disjoint core writes, no lost rows.

    No image-sized padded copy is needed. A cancelled synchronous native call
    returns before its session can be released/reused; the result is discarded.
    This deliberately serial runner provides isolated reference timings, not a
    performance claim. A future app must use its shared AIResourceBudget lease.
    """
    np = numpy()
    tensor(arr, arr.shape[1] if arr.ndim == 4 else 0)
    if type(tile_size) is not int or type(overlap) is not int or tile_size <= 2*overlap or overlap < 0:
        raise ValueError("invalid tile/halo")
    if scale not in (1, 2) or output_channels != 3:
        raise ValueError("unsupported output contract")
    h, w = arr.shape[2:]
    core = tile_size-2*overlap
    needed = arr.nbytes + 4*(output_channels*h*w*scale*scale +
                            arr.shape[1]*tile_size*tile_size +
                            output_channels*tile_size*tile_size*scale*scale)
    if needed > max_tensor_bytes:
        raise ValueError("tensor budget exceeded before allocation")
    out = np.empty((1, output_channels, h*scale, w*scale), dtype=np.float32)
    for y in range(0, h, core):
        for x in range(0, w, core):
            if cancelled():
                raise InterruptedError("cancelled before native call")
            iy = mirror_indices(y-overlap, tile_size, h)
            ix = mirror_indices(x-overlap, tile_size, w)
            patch = np.ascontiguousarray(arr[:, :, iy[:, None], ix])
            predicted = infer(patch)
            if cancelled():
                raise InterruptedError("native call returned; cancelled output discarded")
            tensor(predicted, output_channels,
                   shape=(1, output_channels, tile_size*scale, tile_size*scale))
            oh, ow = min(core, h-y), min(core, w-x)
            halo = overlap*scale
            out[:, :, y*scale:(y+oh)*scale, x*scale:(x+ow)*scale] = predicted[:, :, halo:halo+oh*scale, halo:halo+ow*scale]
    return out


def preserve_alpha(rgb, alpha):
    """No alpha inference or premultiplication; preserve the caller's exact bits."""
    np = numpy()
    tensor(rgb, 3)
    tensor(alpha, 1, shape=(1, 1, *rgb.shape[2:]), unit_range=True)
    return np.concatenate((rgb, alpha), axis=1)


def match_gain(predicted, anchor):
    np = numpy()
    if not np.isfinite(predicted).all() or not np.isfinite(anchor).all():
        raise ValueError("nonfinite gain input")
    mean = float(predicted.mean(dtype=np.float64))
    anchor_mean = float(anchor.mean(dtype=np.float64))
    # Stricter than the upstream demo's sign-flipping mean match: negative or
    # zero physical-light means must not be repaired into apparently valid RAW.
    if mean < 1e-12 or anchor_mean < 1e-12:
        raise ValueError("nonpositive/degenerate physical-light mean; no safe gain match")
    gain = anchor_mean/mean
    result = (predicted*gain).astype(np.float32)
    if not math.isfinite(gain) or not np.isfinite(result).all():
        raise ValueError("nonfinite gain output")
    return result, gain


def pack_bayer(mosaic, *, pattern, black, white, active_area, orientation=1):
    """Explicit RGGB channel order. No mod-16 crop or implicit camera support.

    Metadata levels are phase-specific (R,G1,G2,B); the active rectangle must
    have even origin/dimensions. Other origins require an explicit CFA rephase.
    Saturated sensor values are recorded by the caller, then normalised/clipped.
    White balance is NOT silently applied. The Bayer model learns camera RGB.
    """
    np = numpy()
    if mosaic.ndim != 2 or mosaic.dtype != np.float32 or not np.isfinite(mosaic).all():
        raise ValueError("finite FP32 mosaic required")
    if orientation != 1 or pattern != (("R", "G1"), ("G2", "B")):
        raise ValueError("only explicitly phased, unrotated RGGB qualified by this adapter")
    x, y, w, h = active_area
    if any(type(v) is not int or v < 0 or v % 2 for v in (x,y,w,h)) or min(w,h) == 0:
        raise ValueError("even active sensor rectangle required")
    if x+w > mosaic.shape[1] or y+h > mosaic.shape[0]:
        raise ValueError("active sensor rectangle outside mosaic")
    if len(black) != 4 or len(white) != 4 or any(not math.isfinite(b) or not math.isfinite(v) or v <= b for b,v in zip(black,white)):
        raise ValueError("four valid per-phase black/white levels required")
    area = mosaic[y:y+h, x:x+w]
    phases = [area[dy::2,dx::2] for dy,dx in ((0,0),(0,1),(1,0),(1,1))]
    return np.stack([np.clip((p-b)/(v-b),0,1) for p,b,v in zip(phases,black,white)], axis=0)[None].astype(np.float32)


def camera_to_rec2020(rgb, camera_to_xyz_d65):
    """Caller supplies an explicit camera->XYZ D65 matrix, never its inverse by guess."""
    np = numpy()
    tensor(rgb, 3)
    matrix = np.asarray(camera_to_xyz_d65, dtype=np.float64)
    if matrix.shape != (3,3) or not np.isfinite(matrix).all() or np.linalg.cond(matrix) > 1e8:
        raise ValueError("finite nonsingular camera-to-XYZ D65 matrix required")
    xyz_to_2020 = np.array([[1.716651188,-.355670784,-.253366281],
                            [-.666684352,1.616481237,.015768546],
                            [.017639857,-.042770613,.942103121]])
    out = np.einsum("ij,bjhw->bihw", xyz_to_2020@matrix, rgb).astype(np.float32)
    return tensor(out, 3)


class OnnxCPU:
    def __init__(self, snapshot, expected_sha256, inputs, outputs):
        if not isinstance(snapshot,FileSnapshot) or not expected_sha256 or snapshot.digest != expected_sha256:
            raise ValueError("model SHA-256 mismatch")
        reject_external_data(snapshot.data)
        try:
            import onnxruntime as ort
        except ImportError as error:
            raise ValueError("pinned onnxruntime required for reference inference") from error
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        started = time.perf_counter()
        self.session = ort.InferenceSession(snapshot.data, options, providers=["CPUExecutionProvider"])
        self.load_seconds = time.perf_counter()-started
        self.sha256 = expected_sha256
        for observed, expected in ((self.session.get_inputs(), inputs), (self.session.get_outputs(), outputs)):
            actual = {t.name:(t.type, tuple(t.shape)) for t in observed}
            if actual != expected:
                raise ValueError(f"tensor contract mismatch: {actual}")
        if self.session.get_providers() != ["CPUExecutionProvider"]:
            raise ValueError("unexpected execution provider")
        self.timings = []

    def run(self, values):
        started = time.perf_counter()
        result = self.session.run(None, values)
        self.timings.append(time.perf_counter()-started)
        return result


class SegNext:
    """Synchronous source-scoped proposals; no persisted/app mask mutation."""
    def __init__(self, encoder, decoder, cache_bytes=32*1024*1024):
        if cache_bytes < 0 or cache_bytes > 64*1024*1024:
            raise ValueError("cache budget outside 0..64 MiB")
        self.encoder, self.decoder = encoder, decoder
        self.cache_bytes, self.cache = cache_bytes, OrderedDict()

    def refine(self, image, frame, clicks, *, previous=None, cancelled=lambda: False):
        np = numpy()
        tensor(image, 3, shape=(1,3,1024,1024), unit_range=True)
        if not 1 <= len(clicks) <= 10:
            raise ValueError("one to ten positive/negative correction clicks required")
        coords, labels = [], []
        for click in clicks:
            if click["label"] not in (0,1):
                raise ValueError("foreground/background labels only; padding is internal")
            coords.append(frame.to_prompt(click["point"], source_sha256=click["source_sha256"], frame_id=click["frame_id"]))
            labels.append(click["label"])
        history = tuple((float(x), float(y), int(label)) for (x,y),label in zip(coords,labels))
        key = (frame.identity, hashlib.sha256(image.tobytes()).hexdigest(), self.encoder.sha256, self.decoder.sha256)
        prev = np.zeros((1,1,1024,1024), dtype=np.float32)
        if previous is not None:
            if previous["key"] != key:
                raise ValueError("previous mask belongs to another source/preparation/model")
            if history[:-1] != previous["history"]:
                raise ValueError("iteration must retain all previous clicks and append exactly one")
            prev = previous["binary"]
            tensor(prev, 1, shape=(1,1,1024,1024))
            if not np.isin(prev, (0,1)).all():
                raise ValueError("prev_mask must be binary FP32 0/1, never SAM logits or a BiRefNet alpha")
        if cancelled():
            raise InterruptedError("cancelled before encoder")
        feats = self.cache.pop(key, None)
        if feats is None:
            feats, = self.encoder.run({"image": image})
            tensor(feats, 768, shape=(1,768,64,64))
        if cancelled():
            raise InterruptedError("encoder returned; stale features discarded")
        if feats.nbytes <= self.cache_bytes:
            while self.cache and sum(v.nbytes for v in self.cache.values()) + feats.nbytes > self.cache_bytes:
                self.cache.popitem(last=False)
            self.cache[key] = feats
        logits, = self.decoder.run({"image_feats":feats, "point_coords":np.array([coords],dtype=np.float32),
                                   "point_labels":np.array([labels],dtype=np.float32), "prev_mask":prev})
        if cancelled():
            raise InterruptedError("decoder returned; stale proposal discarded")
        tensor(logits, 1, shape=(1,1,1024,1024))
        return {"key":key, "history":history, "binary":(logits > 0).astype(np.float32), "logits":logits}

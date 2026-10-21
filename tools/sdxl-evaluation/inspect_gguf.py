#!/usr/bin/env python3
"""Read a bounded GGUF v3 header, without loading tensor data or running an SDK.

Format/enum sources are ggml/include/{gguf.h,ggml.h} at Glowroom's pinned
d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93 revision. Dimensions use GGML
innermost-first order; convolution OIHW dimensions are their reverse.
"""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys


MAX_HEADER_BYTES = 64 * 1024 * 1024
MAX_TENSORS = 10000
MAX_METADATA = 10000
MAX_ARRAY_ITEMS = 1000000
MAX_STRING_BYTES = 1024 * 1024
MAX_NAME_BYTES = 4096
MAX_ALIGNMENT = 1024 * 1024
MAX_ELEMENTS = (1 << 63) - 1
GGML_REVISION = "d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93"
# Removed enum slots (4, 5, 31-33, 36-38) are deliberately unsupported.
TENSOR_TYPES = {
    0: "f32", 1: "f16", 2: "q4_0", 3: "q4_1", 6: "q5_0", 7: "q5_1",
    8: "q8_0", 9: "q8_1", 10: "q2_k", 11: "q3_k", 12: "q4_k", 13: "q5_k",
    14: "q6_k", 15: "q8_k", 16: "iq2_xxs", 17: "iq2_xs", 18: "iq3_xxs",
    19: "iq1_s", 20: "iq4_nl", 21: "iq3_s", 22: "iq2_s", 23: "iq4_xs",
    24: "i8", 25: "i16", 26: "i32", 27: "i64", 28: "f64", 29: "iq1_m",
    30: "bf16", 34: "tq1_0", 35: "tq2_0", 39: "mxfp4", 40: "nvfp4",
    41: "q1_0", 42: "q2_0", 43: "f8_e4m3", 44: "f8_e5m2",
}
# Byte extents are checked for the types produced by this exact conversion.
# Other known types remain visible in counts, and cannot satisfy the Q8 gate.
TENSOR_BLOCKS = {"f32": (1, 4), "f16": (1, 2), "q8_0": (32, 34),
                 "i8": (1, 1), "i16": (1, 2), "i32": (1, 4), "i64": (1, 8),
                 "f64": (1, 8), "bf16": (1, 2), "f8_e4m3": (1, 1), "f8_e5m2": (1, 1)}
METADATA_SCALARS = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i",
                    6: "f", 7: "B", 10: "Q", 11: "q", 12: "d"}
INPUT_CONVOLUTIONS = {
    "model.diffusion_model.input_blocks.0.0.weight",
    "model.diffusion_model.conv_in.weight", "unet.conv_in.weight",
}


class InspectionError(Exception):
    pass


class HeaderReader:
    def __init__(self, stream, file_bytes):
        self.stream = stream
        self.file_bytes = file_bytes
        self.position = 0
        self.bytes_read = 0

    def extent(self, count):
        if count < 0 or self.position + count > min(self.file_bytes, MAX_HEADER_BYTES):
            raise InspectionError("Truncated header or header exceeds the 64 MiB budget")

    def read(self, count):
        self.extent(count)
        data = self.stream.read(count)
        if len(data) != count:
            raise InspectionError("Truncated GGUF header")
        self.position += count
        self.bytes_read += count
        return data

    def skip(self, count):
        self.extent(count)
        self.stream.seek(count, os.SEEK_CUR)
        self.position += count

    def number(self, code):
        return struct.unpack("<" + code, self.read(struct.calcsize("<" + code)))[0]

    def string(self, limit=MAX_STRING_BYTES, keep=True):
        length = self.number("Q")
        if length > limit:
            raise InspectionError("GGUF string exceeds inspection limit")
        if not keep:
            self.skip(length)
            return None
        try:
            value = self.read(length).decode("utf-8")
        except UnicodeDecodeError as error:
            raise InspectionError("Invalid UTF-8 GGUF name") from error
        if not value or "\0" in value:
            raise InspectionError("Empty or NUL-containing GGUF name")
        return value

    def metadata_value(self, kind):
        if kind in METADATA_SCALARS:
            return self.number(METADATA_SCALARS[kind])
        if kind == 8:
            self.string(keep=False)
            return None
        if kind != 9:
            raise InspectionError("Unknown GGUF metadata type")
        element_kind, count = self.number("I"), self.number("Q")
        if count > MAX_ARRAY_ITEMS:
            raise InspectionError("GGUF metadata array exceeds inspection limit")
        if element_kind in METADATA_SCALARS:
            self.skip(count * struct.calcsize("<" + METADATA_SCALARS[element_kind]))
        elif element_kind == 8:
            for _ in range(count):
                self.string(keep=False)
        else:
            # GGUF disallows nested arrays; unknown element enums are rejected.
            raise InspectionError("Unknown or nested GGUF metadata array type")
        return None


def inspect_stream(stream, file_bytes):
    reader = HeaderReader(stream, file_bytes)
    if reader.read(4) != b"GGUF" or reader.number("I") != 3:
        raise InspectionError("Only little-endian GGUF v3 is supported")
    tensor_count, metadata_count = reader.number("Q"), reader.number("Q")
    if not 1 <= tensor_count <= MAX_TENSORS or metadata_count > MAX_METADATA:
        raise InspectionError("GGUF tensor or metadata count exceeds inspection limit")
    alignment, keys = 32, set()
    for _ in range(metadata_count):
        key = reader.string(MAX_NAME_BYTES)
        if key in keys:
            raise InspectionError("Duplicate GGUF metadata key")
        keys.add(key)
        kind = reader.number("I")
        if key == "general.alignment" and kind != 4:
            raise InspectionError("GGUF alignment must be uint32")
        value = reader.metadata_value(kind)
        if key == "general.alignment":
            alignment = value
    if not alignment or alignment > MAX_ALIGNMENT or alignment & (alignment - 1):
        raise InspectionError("Invalid GGUF data alignment")
    tensors, names = [], set()
    counts, vae_counts, vae_bias_counts, vae_nonbias_counts = Counter(), Counter(), Counter(), Counter()
    non_float_q8 = []
    input_conv = None
    for _ in range(tensor_count):
        name = reader.string(MAX_NAME_BYTES)
        if name in names:
            raise InspectionError("Duplicate GGUF tensor name")
        names.add(name)
        dimensions = reader.number("I")
        if not 1 <= dimensions <= 4:
            raise InspectionError("Invalid GGUF tensor dimension count")
        shape, elements = [], 1
        for _ in range(dimensions):
            dimension = reader.number("Q")
            if not dimension or dimension > MAX_ELEMENTS // elements:
                raise InspectionError("Invalid or overflowing GGUF tensor dimensions")
            shape.append(dimension)
            elements *= dimension
        type_id = reader.number("I")
        if type_id not in TENSOR_TYPES:
            raise InspectionError("Unknown or removed GGML tensor type")
        kind, offset = TENSOR_TYPES[type_id], reader.number("Q")
        if offset % alignment:
            raise InspectionError("Unaligned GGUF tensor offset")
        tensor = {"name": name, "ggmlDimensions": shape, "type": kind,
                  "dataRelativeOffset": offset}
        counts[kind] += 1
        if name.startswith(("first_stage_model.", "vae.")):
            vae_counts[kind] += 1
            (vae_bias_counts if name.endswith(".bias") else vae_nonbias_counts)[kind] += 1
        if kind not in {"f32", "f16", "q8_0"}:
            non_float_q8.append({"name": name, "type": kind})
        if name in INPUT_CONVOLUTIONS:
            if input_conv is not None or dimensions != 4:
                raise InspectionError("Ambiguous or invalid input convolution header")
            input_conv = dict(tensor, logicalOIHW=list(reversed(shape)), inputChannels=shape[2])
        tensors.append((tensor, elements))
    header_bytes = reader.position
    data_start = ((header_bytes + alignment - 1) // alignment) * alignment
    reader.extent(data_start - header_bytes)
    payload_bytes = file_bytes - data_start
    extents, incomplete_extents = [], False
    for tensor, elements in tensors:
        offset, kind, shape = tensor["dataRelativeOffset"], tensor["type"], tensor["ggmlDimensions"]
        if offset >= payload_bytes:
            raise InspectionError("GGUF tensor offset is outside file")
        if kind in TENSOR_BLOCKS:
            block, size = TENSOR_BLOCKS[kind]
            if shape[0] % block:
                raise InspectionError("Invalid GGUF quantized row block width")
            end = offset + (elements // block) * size
            if end > payload_bytes:
                raise InspectionError("GGUF tensor payload extent is outside file")
            extents.append((offset, end))
        else:
            incomplete_extents = True
    extents.sort()
    if any(current[0] < previous[1] for previous, current in zip(extents, extents[1:])):
        raise InspectionError("Overlapping GGUF tensor payload extents")
    vae_all_f32 = bool(vae_counts) and set(vae_counts) == {"f32"}
    input_shape = input_conv is not None and input_conv["ggmlDimensions"] == [3, 3, 9, 320]
    return {"schemaVersion": 1, "formatVersion": 3, "sourceFileBytes": file_bytes,
            "tensorCount": tensor_count, "metadataCount": metadata_count,
            "typeCounts": dict(sorted(counts.items())), "vaeTypeCounts": dict(sorted(vae_counts.items())),
            "vaeBiasTypeCounts": dict(sorted(vae_bias_counts.items())),
            "vaeNonBiasTypeCounts": dict(sorted(vae_nonbias_counts.items())),
            "otherTensorTypes": non_float_q8,
            "vaeAllF32": vae_all_f32, "inpaintingInputConvolution": input_conv,
            "sdxlNineChannelInputShapeObserved": input_shape,
            "q8WithF32VAEHeaderObserved": bool(counts["q8_0"]) and set(counts) <= {"f32", "f16", "q8_0"} and vae_all_f32 and input_shape,
            "headerBytes": header_bytes, "headerBytesRead": reader.bytes_read,
            "dataOffset": data_start, "alignment": alignment,
            "payloadExtentCheck": "partial-known-types" if incomplete_extents else "all-declared-extents",
            "tensorDataRead": False, "tensorDataContentsValidated": False,
            "inferenceExecuted": False, "qualityOrProductApproval": False,
            "formatSourceGGMLRevision": GGML_REVISION}


def inspect(path, include_sha256=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    # Unbuffered reads keep the I/O claim literal: no read-ahead into tensors.
    with os.fdopen(descriptor, "rb", buffering=0) as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise InspectionError("GGUF input must be a nonsymbolic regular file")
        result = inspect_stream(stream, before.st_size)
        if include_sha256:
            # Optional full-file I/O is explicit, separate from header inspection
            # and bounded to one 64 KiB chunk in memory. No tensors are decoded.
            stream.seek(0)
            digest = hashlib.sha256()
            while block := stream.read(64 * 1024):
                digest.update(block)
            result["sourceFileSHA256"] = digest.hexdigest()
            result["fullFileReadForSHA256"] = True
            result["tensorDataRead"] = True
        else:
            result["fullFileReadForSHA256"] = False
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise InspectionError("GGUF input changed during inspection")
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="existing GGUF model; read-only")
    parser.add_argument("--sha256", action="store_true", help="also stream full file for SHA256; default reads header only")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(inspect(args.path, args.sha256), indent=2, allow_nan=False))
        return 0
    except (InspectionError, OSError, ValueError) as error:
        print("GGUF header inspection failed: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

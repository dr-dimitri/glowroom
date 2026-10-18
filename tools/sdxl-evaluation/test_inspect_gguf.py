"""Small synthetic GGUF headers only; no weights, SDK, compiler or inference."""

import hashlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("sdxl_gguf_inspection", Path(__file__).with_name("inspect_gguf.py"))
INSPECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECTOR)


def number(code, value):
    return struct.pack("<" + code, value)


def string(value):
    data = value.encode() if isinstance(value, str) else value
    return number("Q", len(data)) + data


def metadata_value(kind, value):
    if kind in INSPECTOR.METADATA_SCALARS:
        return number(INSPECTOR.METADATA_SCALARS[kind], value)
    if kind == 8:
        return string(value)
    if kind == 9:
        element, values = value
        return number("I", element) + number("Q", len(values)) + b"".join(metadata_value(element, item) for item in values)
    return b""


def fixture(tensors=None, metadata=(), version=3, declared_count=None):
    tensors = tensors or [
        {"name": "model.diffusion_model.input_blocks.0.0.weight", "shape": [3, 3, 9, 320], "kind": 1},
        {"name": "model.diffusion_model.attention.weight", "shape": [32, 32], "kind": 8},
        {"name": "first_stage_model.decoder.weight", "shape": [4, 4], "kind": 0}]
    alignment = next((value for key, kind, value in metadata if key == "general.alignment" and kind == 4), 32)
    valid_alignment = alignment if 0 < alignment <= 1024 and not alignment & (alignment - 1) else 32
    result = b"GGUF" + number("I", version) + number("Q", len(tensors) if declared_count is None else declared_count)
    result += number("Q", len(metadata))
    for key, kind, value in metadata:
        result += string(key) + number("I", kind) + metadata_value(kind, value)
    next_offset, payload_bytes = 0, 0
    for tensor in tensors:
        shape, kind = tensor["shape"], tensor["kind"]
        elements = 1
        for dimension in shape:
            elements *= dimension
        # Deliberately malformed headers remain tiny fixtures.
        size = {0: elements * 4, 1: elements * 2, 8: (elements // 32) * 34}.get(kind, 32)
        size = max(1, min(size, 1024 * 1024))
        offset = tensor.get("offset", next_offset)
        result += string(tensor["name"]) + number("I", len(shape))
        result += b"".join(number("Q", value) for value in shape)
        result += number("I", kind) + number("Q", offset)
        next_offset = ((offset + size + valid_alignment - 1) // valid_alignment) * valid_alignment
        payload_bytes = max(payload_bytes, offset + size)
    data_start = ((len(result) + valid_alignment - 1) // valid_alignment) * valid_alignment
    result += b"\0" * (data_start - len(result))
    return result + b"\xA5" * min(payload_bytes, 2 * 1024 * 1024), data_start


class GGUFHeaderTests(unittest.TestCase):
    def test_actual_header_counts_shape_and_f32_vae_without_reading_tensor_bytes(self):
        data, data_start = fixture()

        class HeaderOnly(io.BytesIO):
            def read(self, count=-1):
                if count < 0 or self.tell() + count > data_start:
                    raise AssertionError("Attempt to read tensor data")
                return super().read(count)

        result = INSPECTOR.inspect_stream(HeaderOnly(data), len(data))
        self.assertEqual(result["formatVersion"], 3)
        self.assertEqual(result["tensorCount"], 3)
        self.assertEqual(result["typeCounts"], {"f16": 1, "f32": 1, "q8_0": 1})
        self.assertEqual(result["vaeTypeCounts"], {"f32": 1})
        self.assertEqual(result["inpaintingInputConvolution"]["logicalOIHW"], [320, 9, 3, 3])
        self.assertTrue(result["q8WithF32VAEHeaderObserved"])
        self.assertFalse(result["tensorDataRead"])
        self.assertFalse(result["qualityOrProductApproval"])

    def test_metadata_scalars_strings_and_bounded_arrays_do_not_shift_tensor_headers(self):
        metadata = [("general.alignment", 4, 64), ("description", 8, "fixture description"),
                    ("empty", 8, ""), ("tokens", 9, (8, ["wood", "", "tree"])),
                    ("token_ids", 9, (5, [-1, 0, 1])), ("flags", 9, (7, [0, 1]))]
        for kind, value in [(0, 1), (1, -1), (2, 2), (3, -2), (5, -3), (6, 0.5),
                            (7, 1), (10, 100), (11, -100), (12, 0.25)]:
            metadata.append(("scalar-" + str(kind), kind, value))
        data, data_start = fixture(metadata=metadata)
        result = INSPECTOR.inspect_stream(io.BytesIO(data), len(data))
        self.assertEqual(result["metadataCount"], len(metadata))
        self.assertEqual(result["dataOffset"], data_start)
        self.assertEqual(result["alignment"], 64)
        self.assertTrue(result["q8WithF32VAEHeaderObserved"])

    def test_magic_version_and_bounded_counts_are_rejected(self):
        data, _ = fixture()
        bad = [b"BAD!" + data[4:], data[:4] + number("I", 2) + data[8:],
               data[:8] + number("Q", 0) + data[16:],
               data[:8] + number("Q", 10001) + data[16:],
               data[:16] + number("Q", 10001) + data[24:]]
        for malformed in bad:
            with self.subTest(prefix=malformed[:24]), self.assertRaises(INSPECTOR.InspectionError):
                INSPECTOR.inspect_stream(io.BytesIO(malformed), len(malformed))

    def test_unknown_nested_oversized_or_duplicate_metadata_is_rejected(self):
        invalid = [fixture(metadata=[("unknown", 13, 0)])[0],
                   fixture(metadata=[("same", 4, 1), ("same", 4, 2)])[0],
                   fixture(metadata=[("general.alignment", 4, 3)])[0],
                   fixture(metadata=[("general.alignment", 10, 32)])[0]]
        header = b"GGUF" + number("I", 3) + number("Q", 1) + number("Q", 1)
        invalid += [header + string("array") + number("I", 9) + number("I", kind) + number("Q", 0)
                    for kind in [9, 99]]
        invalid += [header + string("array") + number("I", 9) + number("I", 0) + number("Q", 1000001),
                    header + string("long") + number("I", 8) + number("Q", 1048577)]
        for data in invalid:
            with self.subTest(prefix=data[:80]), self.assertRaises(INSPECTOR.InspectionError):
                INSPECTOR.inspect_stream(io.BytesIO(data), len(data))

    def test_invalid_tensor_type_dimensions_or_duplicate_name_is_rejected(self):
        invalid = [{"name": "x", "shape": [32], "kind": kind} for kind in [4, 45, 99]]
        invalid += [{"name": "x", "shape": shape, "kind": 0}
                    for shape in [[], [1, 1, 1, 1, 1], [0], [1 << 63], [(1 << 62), 4]]]
        for tensor in invalid:
            data, _ = fixture([tensor])
            with self.subTest(tensor=tensor), self.assertRaises(INSPECTOR.InspectionError):
                INSPECTOR.inspect_stream(io.BytesIO(data), len(data))
        data, _ = fixture([{"name": "x", "shape": [1], "kind": 0},
                           {"name": "x", "shape": [1], "kind": 0}])
        with self.assertRaises(INSPECTOR.InspectionError):
            INSPECTOR.inspect_stream(io.BytesIO(data), len(data))

    def test_bad_offsets_truncation_overlap_and_quantized_row_width_are_rejected(self):
        invalid = [fixture([{"name": "x", "shape": [4], "kind": 0, "offset": 1}])[0],
                   fixture([{"name": "x", "shape": [31, 32], "kind": 8}])[0],
                   fixture([{"name": "x", "shape": [4], "kind": 0, "offset": 0},
                            {"name": "y", "shape": [4], "kind": 0, "offset": 0}])[0]]
        data, data_start = fixture()
        invalid += [data[:20], data[:data_start - 1], data[:-1]]
        for malformed in invalid:
            with self.subTest(size=len(malformed)), self.assertRaises(INSPECTOR.InspectionError):
                INSPECTOR.inspect_stream(io.BytesIO(malformed), len(malformed))

    def test_read_only_file_inspection_optional_hash_and_symlink_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "fixture.gguf"
            data, _ = fixture()
            model.write_bytes(data)
            before = (model.stat().st_mtime_ns, model.stat().st_size)
            result = INSPECTOR.inspect(model)
            self.assertNotIn("sourceFileSHA256", result)
            self.assertFalse(result["fullFileReadForSHA256"])
            hashed = INSPECTOR.inspect(model, include_sha256=True)
            self.assertEqual(hashed["sourceFileSHA256"], hashlib.sha256(data).hexdigest())
            self.assertTrue(hashed["fullFileReadForSHA256"])
            self.assertEqual((model.stat().st_mtime_ns, model.stat().st_size), before)
            self.assertEqual(model.read_bytes(), data)
            symbolic = model.with_name("alias.gguf"); symbolic.symlink_to(model)
            with self.assertRaises(OSError):
                INSPECTOR.inspect(symbolic)

    def test_header_budget_and_observed_capabilities_cannot_be_inferred_from_filename(self):
        self.assertEqual(INSPECTOR.MAX_HEADER_BYTES, 64 * 1024 * 1024)
        data, _ = fixture()
        with patch.object(INSPECTOR, "MAX_HEADER_BYTES", 64), self.assertRaises(INSPECTOR.InspectionError):
            INSPECTOR.inspect_stream(io.BytesIO(data), len(data))
        data, _ = fixture([{"name": "vae.decoder.weight", "shape": [4], "kind": 1},
                           {"name": "unet.conv_in.weight", "shape": [3, 3, 4, 320], "kind": 1}])
        result = INSPECTOR.inspect_stream(io.BytesIO(data), len(data))
        self.assertFalse(result["vaeAllF32"])
        self.assertFalse(result["sdxlNineChannelInputShapeObserved"])
        self.assertFalse(result["q8WithF32VAEHeaderObserved"])


if __name__ == "__main__":
    unittest.main()

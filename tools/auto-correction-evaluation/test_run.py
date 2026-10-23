"""Boundary checks for the local runner; no model or private fixture required."""

from hashlib import sha256
import importlib.util
from io import BytesIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
from jsonschema import Draft202012Validator


SPEC = importlib.util.spec_from_file_location("correction_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def encoded_image(color):
    stream = BytesIO()
    Image.new("RGB", (64, 32), color).save(stream, format="PNG")
    return stream.getvalue()


class RunnerBoundaries(unittest.TestCase):
    def test_decoder_subset_preserves_original_and_basic_syntax_limits(self):
        schema = {
            "type": "object", "additionalProperties": False,
            "required": ["version", "tags"],
            "properties": {
                "version": {"const": 1},
                "tags": {"type": "array", "uniqueItems": True, "maxItems": 2,
                         "items": {"type": "string", "enum": ["daylight", "night"]}},
            },
            "allOf": [{"if": {"properties": {"version": {"const": 1}}},
                       "then": {"properties": {"tags": {"maxItems": 1}}}}],
        }
        frozen = json.dumps(schema, sort_keys=True)
        decoder = runner.grammar_schema(schema)
        self.assertEqual(json.dumps(schema, sort_keys=True), frozen)
        Draft202012Validator.check_schema(decoder)
        validator = Draft202012Validator(decoder)
        self.assertTrue(validator.is_valid({"version": 1, "tags": ["daylight"]}))
        for invalid in (
            {"version": 2, "tags": ["daylight"]},
            {"version": 1, "tags": ["unknown"]},
            {"version": 1, "tags": ["daylight"] * 3},
            {"version": 1, "tags": [], "extra": True},
        ):
            self.assertFalse(validator.is_valid(invalid))

    def test_relaxed_decoder_does_not_replace_complete_schema_validation(self):
        schema = {
            "type": "object", "required": ["decision", "tags", "edits"],
            "properties": {
                "decision": {"enum": ["no_op", "local_adjustment"]},
                "tags": {"type": "array", "uniqueItems": True,
                         "items": {"enum": ["daylight", "night"]}},
                "edits": {"type": "array", "items": {"type": "string"}},
            },
            "allOf": [{"if": {"properties": {"decision": {"const": "no_op"}}},
                       "then": {"properties": {"edits": {"maxItems": 0}}}}],
        }
        decoder = Draft202012Validator(runner.grammar_schema(schema))
        complete = Draft202012Validator(schema)
        for invalid in (
            {"decision": "no_op", "tags": ["daylight", "daylight"], "edits": []},
            {"decision": "no_op", "tags": ["daylight"], "edits": ["brighten"]},
        ):
            self.assertTrue(decoder.is_valid(invalid))
            self.assertFalse(complete.is_valid(invalid))

    def test_common_prompt_excludes_case_oracle_and_source_identity(self):
        manifest = {
            "model_prompt_de": "Gemeinsamer Bildauftrag.",
            "response_contract": {"tag_definitions": {"daylight": "Sichtbares Tageslicht."}},
            "cases": [{"id": "PRIVATE_CASE_ID", "expected_de": "SECRET_ORACLE",
                       "source": {"file": "PRIVATE_FILENAME.png"},
                       "semantics": {"required_tag_groups": [["SECRET_TAG"]]}}],
            "original_files_sha256": {"PRIVATE_ORIGINAL.jpg": "SECRET_HASH"},
        }
        prompt = runner.common_prompt(manifest, {"type": "object"})
        self.assertIn("Gemeinsamer Bildauftrag.", prompt)
        self.assertIn("Sichtbares Tageslicht.", prompt)
        for secret in ("PRIVATE_CASE_ID", "SECRET_ORACLE", "PRIVATE_FILENAME", "SECRET_TAG", "SECRET_HASH"):
            self.assertNotIn(secret, prompt)

    def test_prepare_case_rejects_source_outside_fixture_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            outside = root / "outside.png"
            outside.write_bytes(encoded_image("red"))
            for filename in ("../outside.png", "linked.png"):
                if filename == "linked.png":
                    (fixtures / filename).symlink_to(outside)
                case = {"id": "case", "source": {"file": filename}}
                with self.assertRaisesRegex(ValueError, "inside the fixture directory"):
                    runner.prepare_case(case, fixtures, 32)

    def test_source_replacement_cannot_bind_old_hash_to_new_pixels(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "image.png"
            original = encoded_image("red")
            replacement = encoded_image("blue")
            path.write_bytes(original)
            case = {"id": "case", "source": {
                "file": path.name, "sha256": sha256(original).hexdigest(), "width": 64, "height": 32}}
            image_open = Image.open

            def replace_before_decode(source, *args, **kwargs):
                path.write_bytes(replacement)
                return image_open(source, *args, **kwargs)

            with patch.object(runner.Image, "open", side_effect=replace_before_decode):
                result = runner.prepare_case(case, root, 32)
            self.assertEqual(result["source_sha256"], sha256(original).hexdigest())
            self.assertEqual(result["dimensions"], (32, 16))
            self.assertEqual(result["pixels"], bytes([255, 0, 0]) * 32 * 16)

    def test_unresponsive_worker_has_kill_backstop_and_closes_pipe(self):
        class UnresponsiveProcess:
            terminated = False
            killed = False

            def is_alive(self):
                return not self.killed

            def join(self, timeout):
                pass

            def terminate(self):
                self.terminated = True

            def kill(self):
                self.killed = True

        class ClosedConnection:
            closed = False

            def send(self, value):
                raise BrokenPipeError("worker does not receive")

            def close(self):
                self.closed = True

        process, connection = UnresponsiveProcess(), ClosedConnection()
        runner.stop_worker(process, connection)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertTrue(connection.closed)


if __name__ == "__main__":
    unittest.main()

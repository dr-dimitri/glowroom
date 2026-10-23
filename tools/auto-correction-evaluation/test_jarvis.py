"""Local HTTP boundary tests; no model, network service or private photo required."""
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
from io import BytesIO
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from PIL import Image


SPEC = importlib.util.spec_from_file_location("jarvis_runner", Path(__file__).with_name("run_jarvis.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
EVAL_SPEC = importlib.util.spec_from_file_location("jarvis_evaluator", Path(__file__).with_name("evaluate.py"))
evaluator = importlib.util.module_from_spec(EVAL_SPEC)
EVAL_SPEC.loader.exec_module(evaluator)


class JarvisBoundaries(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.reply = {"choices": [{"message": {"content": "  RAW RESPONSE\n"}, "finish_reason": "stop"}],
                      "usage": {"prompt_tokens": 31, "completion_tokens": 7},
                      "timings": {"predicted_n": 7}}
        self.status = 200
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                owner.requests.append(json.loads(body))
                self.send_response(owner.status)
                if owner.status == 302:
                    self.send_header("Location", "https://example.invalid/private-upload")
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                try:
                    self.wfile.write(json.dumps(owner.reply).encode())
                except BrokenPipeError:
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def prepared(self):
        return {"case_id": "SECRET_CASE", "source_sha256": "SECRET_SOURCE_HASH",
                "input_raster_sha256": "SECRET_RASTER_HASH", "dimensions": (2, 1),
                "pixels": bytes([255, 0, 0]) * 2}

    def test_endpoint_is_literal_loopback_only(self):
        self.assertEqual(runner.local_endpoint("http://localhost:8080/v1"), "http://127.0.0.1:8080/v1/chat/completions")
        self.assertEqual(runner.local_endpoint("http://[::1]:8080"), "http://[::1]:8080/v1/chat/completions")
        for invalid in ("http://example.com:8080", "http://192.168.1.3:8080", "http://127.0.0.1",
                        "http://127.0.0.1:8080?target=remote", "http://user@localhost:8080",
                        "http://localhost:8080/#secret", "file:///tmp/file", "http://localhost:8080/upload"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runner.local_endpoint(invalid)

    def test_shared_request_has_anonymous_pixels_and_no_oracle(self):
        manifest = {"model_prompt_de": "Beurteile das Bild.", "response_contract": {"tag_definitions": {}},
                    "cases": [{"id": "SECRET_CASE", "source": {"file": "SECRET_FILENAME.png"}, "expected": "SECRET_ORACLE"}]}
        prompt = runner.common.common_prompt(manifest, {"type": "object"})
        body = runner.make_request(self.prepared(), prompt, "shared", {"type": "object", "uniqueItems": True})
        encoded = json.dumps(body)
        for secret in ("SECRET_CASE", "SECRET_SOURCE_HASH", "SECRET_RASTER_HASH", "SECRET_FILENAME", "SECRET_ORACLE"):
            self.assertNotIn(secret, encoded)
        content = body["messages"][0]["content"]
        data_url = content[1]["image_url"]["url"]
        self.assertTrue(data_url.startswith("data:image/png;base64,"))
        image = Image.open(BytesIO(__import__("base64").b64decode(data_url.split(",", 1)[1])))
        self.assertEqual(image.tobytes(), self.prepared()["pixels"])
        self.assertEqual(image.info, {})
        self.assertFalse(body["cache_prompt"])
        self.assertEqual(body["id_slot"], 0)
        self.assertEqual(body["max_tokens"], 768)
        self.assertNotIn("uniqueItems", body["response_format"]["json_schema"]["schema"])

    def test_native_request_preserves_separate_frozen_prompts(self):
        body = runner.make_request(self.prepared(), "Gemeinsame native Aufgabe.", "native", {}, "UPSTREAM SYSTEM")
        self.assertEqual(body["messages"][0], {"role": "system", "content": "UPSTREAM SYSTEM"})
        self.assertEqual(body["messages"][1]["content"][0]["text"], "Gemeinsame native Aufgabe.")
        self.assertEqual(body["max_tokens"], 2048)
        self.assertNotIn("response_format", body)

    def test_completion_preserves_raw_text_and_truncation(self):
        result = runner.request_inference(self.url, {}, 2)
        self.assertEqual(result["response_text"], "  RAW RESPONSE\n")
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["generation"]["finish_reason"], "stop")
        self.assertEqual(result["server_usage"]["prompt_tokens"], 31)
        self.assertIsNone(result["metrics"]["server_tree_rss_sampled_peak_bytes"])
        self.reply["choices"][0]["finish_reason"] = "length"
        result = runner.request_inference(self.url, {}, 2)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["generation"]["finish_reason"], "length")

    def test_image_token_verification_requires_positive_integer(self):
        for tokens in (None, 0, -1, False, True, "672", 1.5, 672):
            with self.subTest(tokens=tokens):
                self.reply["image_tokens"] = tokens
                result = runner.request_inference(self.url, {}, 2)
                self.assertEqual(result["prepared_inputs"]["image_token_count_verified"], tokens == 672)

    def test_strict_json_rejects_duplicate_and_nonfinite_values(self):
        for invalid in ('{"file":"first","file":"second"}', '{"value":NaN}', '{"value":1e999}'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runner.strict_json(invalid)

    def test_server_binding_requires_declared_binary_and_distinct_ggufs(self):
        root = Path("/tmp/jarvis-test-binding").resolve()
        model = {"root": str(root), "files": [{"file": "model.gguf"}, {"file": "mmproj.gguf"}]}
        runtime = {"root": str(root), "files": [{"file": "bin/llama-server"}]}
        process = Mock()
        process.exe.return_value = str(root / "bin/llama-server")
        arguments = [process.exe.return_value, "-m", str(root / "model.gguf"),
                     "--mmproj", str(root / "mmproj.gguf"), "--parallel", "1",
                     "--host", "127.0.0.1", "--port", "8080"]
        process.cmdline.return_value = arguments
        process.cwd.return_value = str(root)
        process.create_time.return_value = 123.0
        endpoint = "http://127.0.0.1:8080"
        with patch.object(runner.psutil, "Process", return_value=process):
            self.assertEqual(runner.verify_server_binding(42, model, runtime, endpoint)["status"], "verified")
            with self.assertRaisesRegex(ValueError, "host/port"):
                runner.verify_server_binding(42, model, runtime, "http://127.0.0.1:9999")
            with self.assertRaisesRegex(ValueError, "host/port"):
                runner.verify_server_binding(42, model, runtime, "http://[::1]:8080")
            process.exe.return_value = str(root / "wrong-server")
            with self.assertRaisesRegex(ValueError, "executable"):
                runner.verify_server_binding(42, model, runtime, endpoint)
            process.exe.return_value = str(root / "bin/llama-server")
            arguments[2] = str(root / "wrong-model.gguf")
            with self.assertRaisesRegex(ValueError, "hashed GGUF"):
                runner.verify_server_binding(42, model, runtime, endpoint)
            arguments[2] = str(root / "model.gguf")
            arguments[arguments.index("--parallel") + 1] = "2"
            with self.assertRaisesRegex(ValueError, "one explicitly"):
                runner.verify_server_binding(42, model, runtime, endpoint)

    def test_unavailable_os_metrics_do_not_block_inference(self):
        with patch.object(runner.psutil, "swap_memory", side_effect=OSError("denied")), \
             patch.object(runner.psutil, "virtual_memory", side_effect=OSError("denied")):
            result = runner.request_inference(self.url, {}, 2)
        self.assertEqual(result["status"], "completed")
        self.assertIsNone(result["metrics"]["system_swap_used_delta_bytes"])
        self.assertIsNone(result["metrics"]["system_min_available_bytes"])
        self.assertIn("swap_memory: OSError", result["metrics"]["monitor_errors"])

    def test_http_errors_and_bad_choices_are_not_success(self):
        self.status = 400
        result = runner.request_inference(self.url, {}, 2)
        self.assertEqual(result["status"], "inference_error")
        self.assertIn("400", result["error"])
        self.status = 200
        self.reply = {"choices": []}
        self.assertEqual(runner.request_inference(self.url, {}, 2)["status"], "inference_error")
        self.reply = {"choices": [{"message": {"content": None}, "finish_reason": "stop"}]}
        self.assertEqual(runner.request_inference(self.url, {}, 2)["status"], "inference_error")

    def test_proxy_environment_is_ignored_and_redirects_fail_closed(self):
        with patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "no_proxy": ""}):
            self.assertEqual(runner.request_inference(self.url, {}, 2)["status"], "completed")
        self.status = 302
        result = runner.request_inference(self.url, {}, 2)
        self.assertEqual(result["status"], "inference_error")
        self.assertIn("redirect", result["error"])

    def test_provenance_checks_nested_files_sizes_and_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lib").mkdir()
            (root / "lib" / "runtime.dylib").write_bytes(b"pinned")
            entry = {"file": "lib/runtime.dylib", "bytes": 6, "sha256": sha256(b"pinned").hexdigest()}
            provenance = root / "provenance.json"
            provenance.write_text(json.dumps({"root": str(root), "files": [entry]}))
            self.assertEqual(runner.verify_provenance(provenance)["files"], [entry])
            provenance.write_text(json.dumps({"files": [entry]}))
            self.assertEqual(runner.verify_provenance(provenance)["root"], str(root.resolve()))
            (root / "lib" / "runtime.dylib").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                runner.verify_provenance(provenance)
            entry["file"] = "../outside"
            provenance.write_text(json.dumps({"root": str(root), "files": [entry]}))
            with self.assertRaisesRegex(ValueError, "relative"):
                runner.verify_provenance(provenance)

    def test_timeout_is_distinct_and_no_retry(self):
        with patch.object(runner, "build_opener") as mocked:
            mocked.return_value.open.side_effect = TimeoutError("deadline")
            result = runner.request_inference(self.url, {}, .01)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(mocked.return_value.open.call_count, 1)

    def test_main_records_evaluator_compatible_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            stream = BytesIO()
            Image.new("RGB", (64, 32), "red").save(stream, format="PNG")
            pixels = stream.getvalue()
            (fixtures / "PRIVATE_FILENAME.png").write_bytes(pixels)
            case = {"id": "case01", "source": {"file": "PRIVATE_FILENAME.png", "sha256": sha256(pixels).hexdigest(),
                    "width": 64, "height": 32, "mode": "RGB", "format": "PNG"},
                    "semantics": {"required_tag_groups": [["daylight"]], "allowed_positive_tags": ["daylight"]},
                    "plan": {"accepted_decisions": ["no_op"], "requires_empty_edits": True}}
            manifest = {"suite_id": "synthetic", "model_prompt_de": "Beurteile das Bild.",
                        "response_contract": {"tag_definitions": {}}, "cases": [case]}
            (fixtures / "expectations.json").write_text(json.dumps(manifest))
            schema = {"type": "object", "required": ["description_de", "tags", "decision", "edits", "warnings"]}
            (fixtures / "response.schema.json").write_text(json.dumps(schema))
            artifact = root / "model.gguf"
            artifact.write_bytes(b"test")
            provenance = root / "provenance.json"
            provenance.write_text(json.dumps({"root": str(root), "files": [{"file": artifact.name, "bytes": 4, "sha256": sha256(b"test").hexdigest()}]}))
            answer = {"description_de": "Tageslicht.", "tags": ["daylight"], "decision": "no_op", "edits": [], "warnings": []}
            self.reply["choices"][0]["message"]["content"] = json.dumps(answer)
            output = root / "results"
            args = ["--fixtures", str(fixtures), "--output", str(output), "--server-url", self.url,
                    "--mode", "shared", "--model-provenance", str(provenance), "--runtime-provenance", str(provenance),
                    "--server-pid", str(os.getpid())]
            with patch.object(runner.subprocess, "check_output", return_value="test-environment\n"), \
                 patch.object(runner.platform, "platform", return_value="TestOS"), \
                 patch.object(runner, "verify_server_binding", return_value={"status": "test_double"}):
                self.assertEqual(runner.main(args), 0)
            evaluated = evaluator.evaluate_suite(fixtures, output / "responses")
            self.assertEqual(evaluated["cases"][0]["machine_status"], "passed")
            run = json.loads((output / "run.json").read_text())
            self.assertEqual(run["render_status"], "notRun")
            self.assertEqual(run["selection"]["kind"], "complete_suite")
            self.assertNotIn("PRIVATE_FILENAME", json.dumps(self.requests))
            self.reply["choices"][0]["finish_reason"] = "length"
            args[args.index(str(output))] = str(root / "truncated")
            with patch.object(runner.subprocess, "check_output", return_value=""), \
                 patch.object(runner.platform, "platform", return_value="TestOS"), \
                 patch.object(runner, "verify_server_binding", return_value={"status": "test_double"}):
                self.assertEqual(runner.main(args), 0)
            evaluated = evaluator.evaluate_suite(fixtures, root / "truncated" / "responses")
            self.assertEqual(evaluated["cases"][0]["machine_status"], "schemaError")


if __name__ == "__main__":
    unittest.main()

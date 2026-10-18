"""Offline conversion-wrapper tests with tiny fake helpers, never model work."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("sdxl_conversion", Path(__file__).with_name("convert.py"))
CONVERTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONVERTER)


def fixture(root, mode="success"):
    root.mkdir(mode=0o700)
    tools = root / "fixture-tools"
    tools.mkdir()
    source_payloads = {"helper.cpp": b"fixture helper source\n",
                       "sdk-sdxl-inpaint.patch": b"fixture SDK correction patch\n",
                       "sdk_name_regression.cpp": b"fixture name regression source\n",
                       "sdk-sdxl-mask.patch": b"fixture SDXL mask variant patch\n",
                       "sdxl_mask_regression.cpp": b"fixture SDXL mask regression source\n",
                       "sdxl_reference_schedule.h": b"fixture SDXL reference schedule\n",
                       "sdxl_schedule_regression.cpp": b"fixture SDXL schedule regression\n",
                       "ggml-metal-group-norm.patch": b"fixture GGML Metal correction patch\n",
                       "ggml_group_norm_regression.cpp": b"fixture group normalization regression source\n"}
    for name, data in source_payloads.items():
        (tools / name).write_bytes(data)
    (tools / "package.json").write_bytes((CONVERTER.TOOLS / "package.json").read_bytes())
    payloads = {"source-model/unet/model.safetensors": b"tiny verified input",
                "source-model/model_index.json": b"{}\n",
                "downloads/source.tar.gz": b"fixture source archive"}
    package = {"schemaVersion": 1, "purpose": "fixture-offline-conversion-only", "model": "fixture/model",
               "revision": "fixture-revision", "sdkRevision": "fixture-sdk", "ggmlRevision": "fixture-ggml",
               "files": [{"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                         for name, data in payloads.items()]}
    for name, data in payloads.items():
        path = root / "inputs" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (root / "inputs/installation.json").write_text(json.dumps(package))
    event = {"event": "converted", "status": "success", "protocol": 1,
             "output": "model-q8_0.gguf", "conversionType": "q8_0", "tensorTypeRules": CONVERTER.VAE_RULES,
             "threads": 2, "inferenceExecuted": False, "bytes": 16, "seconds": 0.01}
    helper_source = "\n".join([
        "#!" + sys.executable,
        "import json, pathlib, sys, time",
        "root = pathlib.Path(sys.argv[2])",
        "assert sys.argv[1] == '--convert' and len(sys.argv) == 3",
        "mode = " + repr(mode),
        "event = json.loads(" + repr(json.dumps(event)) + ")",
        "sys.stderr.buffer.write(b'raw stderr\\x00\\xff\\n'); sys.stderr.flush()",
        "if mode == 'timeout': time.sleep(10)",
        "(root / 'model-q8_0.gguf').write_bytes(b'GGUFfixture-only')",
        "if mode == 'invalid-event': event['conversionType'] = 'f16'",
        "if mode == 'invalid-types': event['tensorTypeCounts'] = {'q4_0': 2, 'f32': 1}",
        "if mode == 'valid-types': event['tensorTypeCounts'] = {'q8_0': 2, 'f16': 3, 'f32': 1}",
        "print(json.dumps(event), flush=True)",
        "if mode == 'duplicate-event': print(json.dumps(event), flush=True)",
        "sys.exit(3 if mode == 'nonzero' else 0)", ""])
    helper = root / "sdxl-helper"
    helper.write_text(helper_source)
    helper.chmod(0o700)
    native = {"schemaVersion": 1, "sdkRevision": package["sdkRevision"], "ggmlRevision": package["ggmlRevision"],
              "helperSHA256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "helperSourceSHA256": hashlib.sha256(source_payloads["helper.cpp"]).hexdigest(),
              "sdkPatchSHA256": hashlib.sha256(source_payloads["sdk-sdxl-inpaint.patch"]).hexdigest(),
              "sdkNameRegressionSourceSHA256": hashlib.sha256(source_payloads["sdk_name_regression.cpp"]).hexdigest(),
              "sdkNameRegressionPassed": True,
              "sdkMaskPatchSHA256": hashlib.sha256(source_payloads["sdk-sdxl-mask.patch"]).hexdigest(),
              "sdkMaskRegressionSourceSHA256": hashlib.sha256(source_payloads["sdxl_mask_regression.cpp"]).hexdigest(),
              "sdkMaskFixtureSHA256": CONVERTER.MASK_FIXTURE_SHA256,
              "sdkMaskBaselineReproduced": True, "sdkMaskRegressionPassed": True,
              "sdxlMaskInterpolation": "nearest-v1",
              "sdkScheduleSourceSHA256": hashlib.sha256(source_payloads["sdxl_reference_schedule.h"]).hexdigest(),
              "sdkScheduleRegressionSourceSHA256": hashlib.sha256(source_payloads["sdxl_schedule_regression.cpp"]).hexdigest(),
              "sdkScheduleBaselineReproduced": True, "sdkScheduleRegressionPassed": True,
              "sdxlSchedule": "euler-leading-strength099-v1",
              "ggmlPatchSHA256": hashlib.sha256(source_payloads["ggml-metal-group-norm.patch"]).hexdigest(),
              "metalGroupNormRegressionSourceSHA256": hashlib.sha256(source_payloads["ggml_group_norm_regression.cpp"]).hexdigest(),
              "metalGroupNormBaselineReproduced": True,
              "metalGroupNormRegressionPassed": True,
              "publicHelperSDKAPIOnly": True}
    (root / "native-installation.json").write_text(json.dumps(native))
    return package


class ConversionTests(unittest.TestCase):
    def test_reference_schedule_provenance_is_required_before_helper_start(self):
        changes = [
            ("sdkScheduleSourceSHA256", None), ("sdkScheduleSourceSHA256", "changed"),
            ("sdkScheduleRegressionSourceSHA256", None), ("sdkScheduleRegressionSourceSHA256", "changed"),
            ("sdkScheduleBaselineReproduced", None), ("sdkScheduleBaselineReproduced", False),
            ("sdkScheduleRegressionPassed", None), ("sdkScheduleRegressionPassed", False),
            ("sdxlSchedule", None), ("sdxlSchedule", "discrete"),
            ("header-source", b"mutated schedule\n"), ("regression-source", b"mutated regression\n"),
        ]
        for field, value in changes:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                path = root / "native-installation.json"
                native = json.loads(path.read_text())
                if field == "header-source":
                    (root / "fixture-tools/sdxl_reference_schedule.h").write_bytes(value)
                elif field == "regression-source":
                    (root / "fixture-tools/sdxl_schedule_regression.cpp").write_bytes(value)
                elif value is None:
                    del native[field]
                else:
                    native[field] = value
                path.write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaisesRegex(CONVERTER.PreparationError, "reference schedule or CPU regression"):
                        CONVERTER.convert(root)
                self.assertFalse((root / "conversion-events.jsonl").exists())
                self.assertFalse((root / "conversion.json").exists())
                self.assertFalse((root / ".sdxl-conversion.lock").exists())

    def test_mask_variant_and_cpu_baseline_evidence_are_required_before_helper_start(self):
        changes = [
            ("sdkMaskPatchSHA256", None), ("sdkMaskPatchSHA256", "changed"),
            ("sdkMaskRegressionSourceSHA256", None), ("sdkMaskRegressionSourceSHA256", "changed"),
            ("sdkMaskFixtureSHA256", None), ("sdkMaskFixtureSHA256", "changed"),
            ("sdkMaskBaselineReproduced", None), ("sdkMaskBaselineReproduced", False),
            ("sdkMaskRegressionPassed", None), ("sdkMaskRegressionPassed", False),
            ("sdxlMaskInterpolation", None), ("sdxlMaskInterpolation", "nearest-max"),
            ("patch-source", b"mutated mask patch\n"), ("regression-source", b"mutated CPU regression\n"),
        ]
        for field, value in changes:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                path = root / "native-installation.json"
                native = json.loads(path.read_text())
                if field == "patch-source":
                    (root / "fixture-tools/sdk-sdxl-mask.patch").write_bytes(value)
                elif field == "regression-source":
                    (root / "fixture-tools/sdxl_mask_regression.cpp").write_bytes(value)
                elif value is None:
                    del native[field]
                else:
                    native[field] = value
                path.write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaisesRegex(CONVERTER.PreparationError, "mask patch or CPU regression"):
                        CONVERTER.convert(root)
                self.assertFalse((root / "conversion-events.jsonl").exists())
                self.assertFalse((root / "conversion.json").exists())
                self.assertFalse((root / ".sdxl-conversion.lock").exists())

    def test_ggml_patch_and_real_metal_regression_evidence_are_required_before_helper_start(self):
        changes = [
            ("ggmlPatchSHA256", None), ("ggmlPatchSHA256", "changed"),
            ("metalGroupNormRegressionSourceSHA256", None), ("metalGroupNormRegressionSourceSHA256", "changed"),
            ("metalGroupNormBaselineReproduced", None), ("metalGroupNormBaselineReproduced", False),
            ("metalGroupNormRegressionPassed", None), ("metalGroupNormRegressionPassed", False),
            ("patch-source", b"mutated local patch\n"), ("regression-source", b"mutated local regression\n"),
        ]
        for field, value in changes:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                path = root / "native-installation.json"
                native = json.loads(path.read_text())
                if field == "patch-source":
                    (root / "fixture-tools/ggml-metal-group-norm.patch").write_bytes(value)
                elif field == "regression-source":
                    (root / "fixture-tools/ggml_group_norm_regression.cpp").write_bytes(value)
                elif value is None:
                    del native[field]
                else:
                    native[field] = value
                path.write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaises(CONVERTER.PreparationError):
                        CONVERTER.convert(root)
                self.assertFalse((root / "conversion-events.jsonl").exists())
                self.assertFalse((root / "conversion.json").exists())
                self.assertFalse((root / ".sdxl-conversion.lock").exists())

    def test_missing_or_mismatched_sdk_patch_and_unpassed_regression_are_rejected(self):
        for mode in ["missing-patch-hash", "wrong-patch-hash", "wrong-regression-hash", "regression-false"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                path = root / "native-installation.json"
                native = json.loads(path.read_text())
                if mode == "missing-patch-hash":
                    del native["sdkPatchSHA256"]
                elif mode == "wrong-patch-hash":
                    native["sdkPatchSHA256"] = "changed"
                elif mode == "wrong-regression-hash":
                    native["sdkNameRegressionSourceSHA256"] = "changed"
                else:
                    native["sdkNameRegressionPassed"] = False
                path.write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaises(CONVERTER.PreparationError):
                        CONVERTER.convert(root)
                self.assertFalse((root / "conversion-events.jsonl").exists())
                self.assertFalse((root / "conversion.json").exists())

    def test_new_public_helper_contract_takes_precedence_over_legacy_fallback(self):
        for mode in ["new", "legacy", "new-false-legacy-true"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                path = root / "native-installation.json"
                native = json.loads(path.read_text())
                if mode == "legacy":
                    del native["publicHelperSDKAPIOnly"]
                    native["publicSDKAPIOnly"] = True
                elif mode == "new-false-legacy-true":
                    native["publicHelperSDKAPIOnly"] = False
                    native["publicSDKAPIOnly"] = True
                path.write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"):
                    if mode == "new-false-legacy-true":
                        with self.assertRaises(CONVERTER.PreparationError):
                            CONVERTER.verify_native(root, package)
                    else:
                        self.assertEqual(CONVERTER.verify_native(root, package)[0], root / "sdxl-helper")

    def test_default_plan_requires_no_inputs_and_never_starts_a_helper_or_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "missing"
            output = io.StringIO()
            with patch.object(CONVERTER, "convert", side_effect=AssertionError("conversion")), \
                    patch.object(CONVERTER.PREPARATION, "load_package", side_effect=AssertionError("package access")), \
                    patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(CONVERTER.main(["--root", str(root)]), 0)
            self.assertFalse(root.exists())
            self.assertEqual(json.loads(output.getvalue())["action"], "plan")

    def test_success_preserves_raw_logs_and_records_actual_model_and_helper_hashes(self):
        for mode in ["success", "valid-types"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root, mode)
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package):
                    result = CONVERTER.convert(root)
                receipt = json.loads((root / "conversion.json").read_text())
                self.assertEqual(result, receipt)
                self.assertEqual(receipt["modelSHA256"], hashlib.sha256((root / "model-q8_0.gguf").read_bytes()).hexdigest())
                self.assertEqual(receipt["helperSHA256"], hashlib.sha256((root / "sdxl-helper").read_bytes()).hexdigest())
                self.assertEqual(receipt["modelBytes"], 16)
                self.assertFalse(receipt["inferenceExecuted"])
                self.assertEqual(receipt["productCapability"], "unavailable")
                self.assertEqual((root / "conversion-stderr.bin").read_bytes(), b"raw stderr\x00\xff\n")
                self.assertEqual(json.loads((root / "conversion-events.jsonl").read_text()), receipt["native"])
                self.assertFalse((root / ".sdxl-conversion.lock").exists())
                self.assertFalse(list(root.glob(".sdxl-conversion-receipt-*")))

    def test_invalid_inputs_or_native_provenance_stop_before_process_or_logs(self):
        for mode in ["missing", "corrupt", "symbolic", "helper-mutation", "source-hash", "sdk"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                source = root / "inputs/source-model/unet/model.safetensors"
                if mode == "missing":
                    source.unlink()
                elif mode == "corrupt":
                    source.write_bytes(b"X" * source.stat().st_size)
                elif mode == "symbolic":
                    source.rename(root / "external"); source.symlink_to(root / "external")
                elif mode == "helper-mutation":
                    with (root / "sdxl-helper").open("a") as helper:
                        helper.write("# changed\n")
                else:
                    native = json.loads((root / "native-installation.json").read_text())
                    native["helperSourceSHA256" if mode == "source-hash" else "sdkRevision"] = "changed"
                    (root / "native-installation.json").write_text(json.dumps(native))
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaises((CONVERTER.PreparationError, OSError)):
                        CONVERTER.convert(root)
                self.assertFalse((root / "conversion.json").exists())
                self.assertFalse((root / "conversion-events.jsonl").exists())
                self.assertFalse((root / ".sdxl-conversion.lock").exists())

    def test_existing_outputs_or_foreign_lock_are_never_removed_or_replaced(self):
        names = ["model-q8_0.gguf", "conversion.json", "conversion-events.jsonl",
                 "conversion-stderr.bin", ".sdxl-conversion.lock"]
        for name in names:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root)
                foreign = root / name
                foreign.write_bytes(b"foreign data")
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                        patch.object(CONVERTER.subprocess, "Popen", side_effect=AssertionError("process")):
                    with self.assertRaises((CONVERTER.PreparationError, OSError)):
                        CONVERTER.convert(root)
                self.assertEqual(foreign.read_bytes(), b"foreign data")

    def test_failed_or_invalid_native_results_preserve_logs_without_receipt(self):
        for mode in ["nonzero", "invalid-event", "duplicate-event", "invalid-types"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "evaluation"
                package = fixture(root, mode)
                with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package):
                    with self.assertRaises(CONVERTER.PreparationError):
                        CONVERTER.convert(root)
                self.assertTrue((root / "conversion-events.jsonl").is_file())
                self.assertTrue((root / "conversion-stderr.bin").is_file())
                self.assertFalse((root / "conversion.json").exists())
                self.assertFalse((root / ".sdxl-conversion.lock").exists())

    def test_timeout_kills_and_reaps_exact_helper_before_returning_without_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evaluation"
            package = fixture(root, "timeout")
            observed = []
            popen = subprocess.Popen

            def launch(*args, **kwargs):
                process = popen(*args, **kwargs)
                observed.append(process)
                return process

            with patch.object(CONVERTER, "TOOLS", root / "fixture-tools"), \
                        patch.object(CONVERTER.PREPARATION, "load_package", return_value=package), \
                    patch.object(CONVERTER, "MAX_CONVERSION_SECONDS", 0.05), \
                    patch.object(CONVERTER.subprocess, "Popen", side_effect=launch):
                with self.assertRaises(subprocess.TimeoutExpired):
                    CONVERTER.convert(root)
            self.assertEqual(len(observed), 1)
            self.assertIsNotNone(observed[0].returncode)
            self.assertLess(observed[0].returncode, 0)
            self.assertFalse((root / "conversion.json").exists())
            self.assertFalse((root / ".sdxl-conversion.lock").exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(observed[0].pid, 0)


if __name__ == "__main__":
    unittest.main()

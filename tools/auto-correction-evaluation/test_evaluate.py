"""Isolated evaluator tests; no local photographs, weights or inference needed."""

from copy import deepcopy
from hashlib import sha256
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

SPEC = importlib.util.spec_from_file_location("auto_correction_evaluate", Path(__file__).with_name("evaluate.py"))
evaluate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluate)


SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object", "additionalProperties": False,
    "required": ["schema_version", "tags", "description_de", "decision", "edits", "warnings"],
    "properties": {
        "schema_version": {"const": 1},
        "tags": {"type": "array", "uniqueItems": True, "items": {"type": "string"}},
        "description_de": {"type": "string", "minLength": 1, "maxLength": 2048},
        "decision": {"enum": ["no_op", "global_adjustment", "local_adjustment", "limitations_only", "abstain"]},
        "edits": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["scope", "target", "operation", "direction", "strength"],
            "properties": {"scope": {"enum": ["global", "local"]}, "target": {"type": "string"},
                           "operation": {"enum": ["brightness"]}, "direction": {"enum": ["increase", "decrease"]},
                           "strength": {"enum": ["small", "moderate", "strong"]}}}},
        "warnings": {"type": "array", "uniqueItems": True, "items": {"type": "string"}}}}


def edit(scope="local", target="face", direction="increase", strength="small"):
    return dict(scope=scope, target=target, operation="brightness", direction=direction, strength=strength)


def rule(scope="local", target="face", strengths=None):
    result = edit(scope=scope, target=target)
    result.pop("strength")
    result["allowed_strengths"] = strengths or ["small", "moderate"]
    return result


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.fixtures, self.responses = root / "fixtures", root / "responses"
        self.fixtures.mkdir(); self.responses.mkdir()
        image_path = self.fixtures / "input.png"
        Image.new("RGB", (8, 8), (40, 80, 120)).save(image_path)
        self.digest = sha256(image_path.read_bytes()).hexdigest()
        self.case = {
            "id": "case_01", "source": {"file": "input.png", "sha256": self.digest,
                "width": 8, "height": 8, "mode": "RGB", "format": "PNG",
                "embedded_icc": False, "embedded_exif": False},
            "semantics": {"required_tag_groups": [["landscape"], ["balanced_exposure"]],
                "allowed_positive_tags": ["landscape", "balanced_exposure", "daylight"],
                "forbidden_tags": ["night", "underexposed"]},
            "plan": {"accepted_decisions": ["no_op"], "requires_empty_edits": True,
                "required_edit_rules": [], "required_edit_rules_mode": "all", "alternative_edit_rules": [],
                "required_warnings": [], "conditional_required_warnings": {}, "forbid_any_other_edits": True}}
        self.answer = {"schema_version": 1, "tags": ["landscape", "balanced_exposure"],
                       "description_de": "Eine ausgewogen belichtete Landschaft.",
                       "decision": "no_op", "edits": [], "warnings": []}
        self.write_contract()

    def write_contract(self):
        (self.fixtures / "expectations.json").write_text(json.dumps({"suite_id": "isolated-tests", "cases": [self.case]}))
        (self.fixtures / "response.schema.json").write_text(json.dumps(SCHEMA))

    def envelope(self, answer=None, **overrides):
        result = {"case_id": self.case["id"], "source_sha256": self.digest, "status": "completed",
                  "response_text": json.dumps(answer if answer is not None else self.answer, ensure_ascii=False),
                  "generation": {"finish_reason": "stop"}, "metrics": {"seconds": 1.0}}
        result.update(overrides)
        return result

    def run_response(self, answer=None, **overrides):
        self.write_contract()
        (self.responses / (self.case["id"] + ".json")).write_text(json.dumps(self.envelope(answer, **overrides), ensure_ascii=False))
        self.report = evaluate.evaluate_suite(self.fixtures, self.responses)
        return self.report["cases"][0]

    def require_correction(self, required=None, alternatives=None, mode="all"):
        self.case["plan"].update(accepted_decisions=["local_adjustment"], requires_empty_edits=False,
            required_edit_rules=required if required is not None else [rule()],
            required_edit_rules_mode=mode, alternative_edit_rules=alternatives or [], minimum_edit_count=1,
            forbidden_scopes=["global"])
        self.answer.update(decision="local_adjustment", edits=[edit()])

    def test_noop_machine_pass_still_needs_description_review(self):
        result = self.run_response()
        self.assertEqual(result["machine_status"], "passed")
        self.assertEqual(result["status"], "manualReview")
        self.assertEqual(result["manual_review"]["status"], "manualReview")
        self.assertEqual(result["render"]["status"], "notRun")
        self.assertTrue(self.report["summary"]["all_machine_criteria_passed"])
        self.assertEqual(self.report["end_to_end_status"], "notRun")

    def test_brightness_rule_accepts_both_allowed_strengths(self):
        self.require_correction()
        for strength in ("small", "moderate"):
            with self.subTest(strength=strength):
                self.answer["edits"][0]["strength"] = strength
                self.assertEqual(self.run_response()["machine_status"], "passed")

    def test_strong_or_wrong_direction_edits_fail(self):
        self.require_correction()
        for change in ({"strength": "strong"}, {"direction": "decrease"}, {"target": "black_fur"}):
            with self.subTest(change=change):
                self.answer["edits"] = [edit() | change]
                self.assertEqual(self.run_response()["machine_status"], "failed")

    def test_always_noop_does_not_pass_required_correction(self):
        self.require_correction()
        self.answer.update(decision="no_op", edits=[])
        result = self.run_response()
        self.assertEqual(result["machine_status"], "failed")
        self.assertIn("missing_required_edit", result["plan"]["errors"])

    def test_forbidden_and_unknown_tags_have_different_results(self):
        self.answer["tags"].append("night")
        self.assertEqual(self.run_response()["semantics"]["status"], "failed")
        self.answer["tags"][-1] = "unexpected_but_schema_valid"
        result = self.run_response()
        self.assertEqual(result["semantics"]["status"], "manualReview")
        self.assertEqual(result["machine_status"], "manualReview")
        self.assertFalse(self.report["summary"]["all_machine_criteria_passed"])

    def test_missing_required_tag_fails_even_with_noop(self):
        self.answer["tags"] = ["landscape"]
        self.assertEqual(self.run_response()["semantics"]["status"], "failed")

    def test_abstention_is_not_passed_or_noop(self):
        self.answer.update(decision="abstain", tags=[])
        result = self.run_response()
        self.assertEqual(result["status"], "abstained")
        self.assertEqual(result["semantics"]["status"], "failed")
        self.assertEqual(result["plan"]["status"], "abstained")

    def test_wrong_source_hash_and_case_id_in_envelope_are_invalid(self):
        for override in ({"source_sha256": "0" * 64}, {"case_id": "other_case"}):
            with self.subTest(override=override):
                self.assertEqual(self.run_response(**override)["status"], "fixtureInvalid")

    def test_source_file_hash_is_checked_before_response(self):
        (self.fixtures / "input.png").write_bytes(b"changed source")
        self.assertEqual(self.run_response()["source"]["status"], "fixtureInvalid")
        self.assertEqual(self.report["status"], "fixtureInvalid")

    def test_source_dimensions_are_checked_even_when_hash_matches(self):
        self.case["source"]["width"] = 9
        self.assertEqual(self.run_response()["source"]["status"], "fixtureInvalid")

    def test_source_decode_uses_the_hashed_snapshot_when_path_is_replaced(self):
        source = self.fixtures / "input.png"
        replacement = io.BytesIO()
        Image.new("RGB", (9, 9), (200, 30, 10)).save(replacement, format="PNG")
        read_bytes = Path.read_bytes

        def replace_after_read(path):
            data = read_bytes(path)
            if path == source:
                path.write_bytes(replacement.getvalue())
            return data

        with patch.object(Path, "read_bytes", replace_after_read):
            result = evaluate._source_check(self.fixtures, self.case)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["sha256"], self.digest)
        self.assertNotEqual(sha256(source.read_bytes()).hexdigest(), self.digest)

    def test_missing_fixture_is_not_a_model_failure_or_pass(self):
        (self.fixtures / "input.png").unlink()
        result = self.run_response()
        self.assertEqual(result["status"], "missingFixtures")
        self.assertEqual(result["inference"]["status"], "notRun")
        self.assertEqual(self.report["status"], "missingFixtures")

    def test_missing_response_timeout_and_inference_error_are_not_run(self):
        report = evaluate.evaluate_suite(self.fixtures, self.responses)
        self.assertEqual(report["cases"][0]["status"], "notRun")
        for status in ("timeout", "inference_error"):
            with self.subTest(status=status):
                result = self.run_response(status=status)
                self.assertEqual(result["status"], "notRun")
                self.assertEqual(result["inference"]["status"], status)

    def test_duplicate_keys_nonfinite_markdown_and_extra_values_are_rejected(self):
        valid = json.dumps(self.answer)
        for raw in (valid.replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1'),
                    valid.replace('"schema_version": 1', '"schema_version": NaN'),
                    valid.replace('"schema_version": 1', '"schema_version": Infinity'),
                    valid.replace('"schema_version": 1', '"schema_version": 1e10000'),
                    '```json\n' + valid + '\n```', valid + '\n{}'):
            with self.subTest(raw=raw[:80]):
                self.assertEqual(self.run_response(response_text=raw)["status"], "schemaError")
        self.assertEqual(self.run_response(response_text=' \n' + valid + '\t ')["machine_status"], "passed")

    def test_length_finish_reason_rejects_even_complete_json(self):
        result = self.run_response(generation={"finish_reason": "length"})
        self.assertEqual(result["status"], "schemaError")
        self.assertEqual(result["schema"]["errors"][0]["message"], "generation_truncated")

    def test_utf8_byte_limit_is_additional_to_character_limit(self):
        self.answer["description_de"] = "ä" * 1025
        self.assertEqual(self.run_response()["status"], "schemaError")
        self.answer["description_de"] = "ä" * 1024
        self.assertEqual(self.run_response()["machine_status"], "passed")

    def test_required_all_any_and_alternative_rules(self):
        self.require_correction(required=[rule(target="face"), rule(target="person")], mode="all")
        self.assertEqual(self.run_response()["plan"]["status"], "failed")
        self.case["plan"]["required_edit_rules_mode"] = "any"
        self.assertEqual(self.run_response()["machine_status"], "passed")
        self.case["plan"]["required_edit_rules"] = []
        self.case["plan"]["alternative_edit_rules"] = [rule(target="person"), rule(target="face")]
        self.assertEqual(self.run_response()["machine_status"], "passed")

    def test_additional_edit_cannot_hide_behind_valid_required_edit(self):
        self.require_correction()
        self.answer["edits"].append(edit(target="black_fur"))
        result = self.run_response()
        self.assertIn("unapproved_edit", result["plan"]["errors"])

    def test_optional_small_local_edit_and_noop(self):
        self.case["plan"].update(accepted_decisions=["no_op", "local_adjustment"], requires_empty_edits=False,
            optional_edit_rule=rule(target="black_fur", strengths=["small"]), forbidden_scopes=["global"])
        self.assertEqual(self.run_response()["machine_status"], "passed")
        self.answer.update(decision="local_adjustment", edits=[edit(target="black_fur")])
        self.assertEqual(self.run_response()["machine_status"], "passed")
        self.answer["edits"][0]["strength"] = "moderate"
        self.assertEqual(self.run_response()["plan"]["status"], "failed")

    def test_required_and_conditional_warnings(self):
        self.case["plan"].update(accepted_decisions=["limitations_only", "no_op"],
            conditional_required_warnings={"limitations_only": ["local_white_balance_unavailable"]})
        self.assertEqual(self.run_response()["machine_status"], "passed")
        self.answer["decision"] = "limitations_only"
        self.assertEqual(self.run_response()["plan"]["status"], "failed")
        self.answer["warnings"] = ["local_white_balance_unavailable"]
        self.assertEqual(self.run_response()["machine_status"], "passed")
        self.case["plan"]["required_warnings"] = ["missing_highlight_information"]
        self.assertEqual(self.run_response()["plan"]["status"], "failed")

    def test_manifest_missing_or_duplicate_ids_are_not_passed(self):
        (self.fixtures / "expectations.json").unlink()
        self.assertEqual(evaluate.evaluate_suite(self.fixtures, self.responses)["status"], "missingFixtures")
        self.write_contract()
        path = self.fixtures / "expectations.json"
        path.write_text(json.dumps({"cases": [self.case, deepcopy(self.case)]}))
        self.assertEqual(evaluate.evaluate_suite(self.fixtures, self.responses)["status"], "fixtureInvalid")

    def test_cli_writes_report_without_modifying_fixture_contract(self):
        self.run_response()
        manifest = self.fixtures / "expectations.json"
        before = manifest.read_bytes()
        output = Path(self.temporary.name) / "output" / "evaluation.json"
        code = evaluate.main(["--fixtures", str(self.fixtures), "--responses", str(self.responses), "--output", str(output)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.read_text())["status"], "manualReview")
        self.assertEqual(manifest.read_bytes(), before)

    def test_cli_refuses_to_overwrite_fixture_contract(self):
        manifest = self.fixtures / "expectations.json"
        before = manifest.read_bytes()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            evaluate.main(["--fixtures", str(self.fixtures), "--responses", str(self.responses),
                           "--output", str(manifest)])
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(manifest.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

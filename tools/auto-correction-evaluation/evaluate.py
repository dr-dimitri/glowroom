#!/usr/bin/env python3
"""Evaluate saved local VLM responses without running a model or rendering edits.

An exit code of zero means the report was written, not that the candidate passed.
Only schema/semantic/plan checks are automated. Descriptions need independent
review, and rendered correction remains notRun.
"""

from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from io import BytesIO
import json
import math
from pathlib import Path
import re
import tempfile

from jsonschema import Draft202012Validator
from PIL import Image


MAX_RESPONSE_BYTES = 16_384
MAX_DESCRIPTION_BYTES = 2_048
CASE_ID = re.compile(r"[A-Za-z0-9_-]+\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _finite_float(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("non-finite JSON number")
    return result


def _invalid_constant(value):
    raise ValueError(f"invalid JSON number: {value}")


def strict_json(text):
    """Accept one JSON value with whitespace only outside; never repair output."""
    return json.loads(text, object_pairs_hook=_unique_object,
                      parse_float=_finite_float, parse_constant=_invalid_constant)


def read_json(path):
    return strict_json(path.read_text(encoding="utf-8"))


def _local_file(directory, name):
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("expected a local filename without directory components")
    path = directory / name
    if path.resolve().parent != directory.resolve():
        raise ValueError("file resolves outside the supplied directory")
    return path


def _source_check(directory, case):
    try:
        source = case["source"]
        path = _local_file(directory, source["file"])
        expected = source["sha256"]
        if not isinstance(expected, str) or not SHA256.fullmatch(expected):
            raise ValueError("invalid expected SHA-256")
        if not path.is_file():
            return {"status": "missingFixtures", "reason": "source_file_missing"}
        data = path.read_bytes()
        actual = sha256(data).hexdigest()
        if actual != expected:
            return {"status": "fixtureInvalid", "reason": "source_hash_mismatch",
                    "expected_sha256": expected, "actual_sha256": actual}
        # Decode the exact bytes whose identity was checked. Opening the path
        # again could validate a replacement image against the previous hash.
        with Image.open(BytesIO(data)) as image:
            image.load()
            for key, value in (("width", image.width), ("height", image.height),
                               ("mode", image.mode), ("format", image.format)):
                if key in source and source[key] != value:
                    raise ValueError(f"source {key} mismatch")
            if source.get("embedded_icc") is False and image.info.get("icc_profile"):
                raise ValueError("unexpected embedded ICC profile")
            if source.get("embedded_exif") is False and image.getexif():
                raise ValueError("unexpected embedded EXIF")
        return {"status": "passed", "sha256": actual}
    except (KeyError, TypeError, ValueError, OSError) as error:
        return {"status": "fixtureInvalid", "reason": str(error)}


def _matches(edit, rule):
    return (all(edit.get(key) == rule[key]
                for key in ("scope", "target", "operation", "direction"))
            and edit.get("strength") in rule["allowed_strengths"])


def semantic_check(case, answer):
    rules = case["semantics"]
    tags = set(answer["tags"])
    missing = [group for group in rules["required_tag_groups"]
               if not tags.intersection(group)]
    forbidden = sorted(tags.intersection(rules.get("forbidden_tags", [])))
    unexpected = sorted(tags - set(rules.get("allowed_positive_tags", [])))
    # Known false statements fail; unreviewed extras retain the distinct pending
    # state rather than being silently accepted or counted as factual failures.
    unexpected = [tag for tag in unexpected if tag not in forbidden]
    status = ("failed" if missing or forbidden else
              "manualReview" if unexpected else "passed")
    return {"status": status, "missing_required_groups": missing,
            "forbidden_tags": forbidden, "unexpected_tags": unexpected}


def plan_check(case, answer):
    rules = case["plan"]
    edits = answer["edits"]
    decision = answer["decision"]
    errors = []
    if decision == "abstain":
        return {"status": "abstained", "errors": []}
    if decision not in rules["accepted_decisions"]:
        errors.append("decision_not_accepted")
    if (rules.get("requires_empty_edits") or decision in ("no_op", "limitations_only")) and edits:
        errors.append("expected_empty_edits")
    if len(edits) < rules.get("minimum_edit_count", 0):
        errors.append("missing_required_edit")
    if decision in ("global_adjustment", "local_adjustment") and not edits:
        errors.append("adjustment_decision_without_edit")
    expected_scope = {"global_adjustment": "global", "local_adjustment": "local"}.get(decision)
    if expected_scope and any(edit["scope"] != expected_scope for edit in edits):
        errors.append("decision_edit_scope_mismatch")
    if any(edit["scope"] in rules.get("forbidden_scopes", []) for edit in edits):
        errors.append("forbidden_edit_scope")
    warnings = set(answer["warnings"])
    if not set(rules.get("required_warnings", [])).issubset(warnings):
        errors.append("missing_required_warning")
    conditional = rules.get("conditional_required_warnings", {}).get(decision, [])
    if not set(conditional).issubset(warnings):
        errors.append("missing_conditional_warning")
    required = rules.get("required_edit_rules", [])
    alternatives = rules.get("alternative_edit_rules", [])
    if required:
        matches = [any(_matches(edit, rule) for edit in edits) for rule in required]
        mode = rules.get("required_edit_rules_mode", "all")
        if mode not in ("all", "any"):
            raise ValueError("unknown required_edit_rules_mode")
        if not (any(matches) if mode == "any" else all(matches)):
            errors.append("required_edit_rule_not_met")
    if alternatives and not any(_matches(edit, rule) for edit in edits for rule in alternatives):
        errors.append("alternative_edit_rule_not_met")
    allowed = required + alternatives
    if rules.get("optional_edit_rule"):
        allowed = allowed + [rules["optional_edit_rule"]]
    if rules.get("forbid_any_other_edits", True):
        if any(not any(_matches(edit, rule) for rule in allowed) for edit in edits):
            errors.append("unapproved_edit")
    return {"status": "failed" if errors else "passed", "errors": errors}


def _base_result(case_id, source):
    return {"case_id": case_id, "source": source,
            "inference": {"status": "notRun"}, "schema": {"status": "notRun"},
            "semantics": {"status": "notRun"}, "plan": {"status": "notRun"},
            "manual_review": {"status": "notRun", "required": True,
                              "reason": "Independent description review has not been supplied."},
            "render": {"status": "notRun", "reason": "No correction adapter executed."}}


def evaluate_case(fixtures, responses, case, schema):
    case_id = case.get("id", "")
    if not isinstance(case_id, str) or not CASE_ID.fullmatch(case_id):
        result = _base_result(str(case_id), {"status": "fixtureInvalid", "reason": "invalid_case_id"})
        result.update(status="fixtureInvalid", machine_status="fixtureInvalid")
        return result
    source = _source_check(fixtures, case)
    result = _base_result(case_id, source)
    if source["status"] != "passed":
        result.update(status=source["status"], machine_status=source["status"])
        return result
    try:
        path = _local_file(responses, case_id + ".json")
        if not path.is_file():
            result["inference"] = {"status": "notRun", "reason": "response_file_missing"}
            result.update(status="notRun", machine_status="notRun")
            return result
        envelope = read_json(path)
        if not isinstance(envelope, dict):
            raise ValueError("response envelope must be an object")
        if envelope.get("case_id") != case_id or envelope.get("source_sha256") != source["sha256"]:
            result["source"] = {**source, "status": "fixtureInvalid", "reason": "response_source_binding_mismatch"}
            result.update(status="fixtureInvalid", machine_status="fixtureInvalid")
            return result
        inference_status = envelope.get("status")
        if inference_status in ("timeout", "inference_error"):
            result["inference"] = {"status": inference_status}
            result.update(status="notRun", machine_status="notRun")
            return result
        if inference_status != "completed":
            raise ValueError("invalid inference status")
        generation = envelope.get("generation")
        if not isinstance(generation, dict) or generation.get("finish_reason") not in ("stop", "length"):
            raise ValueError("missing or invalid generation finish_reason")
        result["inference"] = {"status": "completed", "finish_reason": generation["finish_reason"]}
        result["metrics"] = envelope.get("metrics", {})
        if generation["finish_reason"] == "length":
            raise ValueError("generation_truncated")
        raw = envelope.get("response_text")
        if not isinstance(raw, str):
            raise ValueError("response_text must be a string")
        if len(raw.encode("utf-8")) > MAX_RESPONSE_BYTES:
            raise ValueError("raw response exceeds byte limit")
        answer = strict_json(raw)
        errors = sorted(Draft202012Validator(schema).iter_errors(answer), key=lambda error: str(list(error.path)))
        if errors:
            result["schema"] = {"status": "schemaError", "errors": [
                {"path": list(error.path), "message": error.message} for error in errors]}
            result.update(status="schemaError", machine_status="schemaError")
            return result
        if len(answer["description_de"].encode("utf-8")) > MAX_DESCRIPTION_BYTES:
            raise ValueError("description_de exceeds UTF-8 byte limit")
    except (ValueError, TypeError, KeyError, OSError, UnicodeError) as error:
        result["schema"] = {"status": "schemaError", "errors": [{"message": str(error)}]}
        result.update(status="schemaError", machine_status="schemaError")
        return result
    result["schema"] = {"status": "passed"}
    result["answer"] = answer
    result["manual_review"]["status"] = "manualReview"
    try:
        result["semantics"] = semantic_check(case, answer)
        result["plan"] = plan_check(case, answer)
    except (KeyError, TypeError, ValueError) as error:
        result.update(status="fixtureInvalid", machine_status="fixtureInvalid")
        result["contract_error"] = str(error)
        return result
    if answer["decision"] == "abstain":
        # Still expose any semantic failures separately; an abstention never
        # becomes a successful required correction or a successful no-op.
        result.update(status="abstained", machine_status="abstained")
    elif "failed" in (result["semantics"]["status"], result["plan"]["status"]):
        result.update(status="failed", machine_status="failed")
    elif result["semantics"]["status"] == "manualReview":
        result.update(status="manualReview", machine_status="manualReview")
    else:
        result.update(status="manualReview", machine_status="passed")
    return result


def evaluate_suite(fixtures, responses):
    fixtures, responses = Path(fixtures), Path(responses)
    manifest_path, schema_path = fixtures / "expectations.json", fixtures / "response.schema.json"
    if not manifest_path.is_file() or not schema_path.is_file():
        return {"schema_version": 1, "status": "missingFixtures", "cases": [],
                "reason": "expectations.json or response.schema.json missing",
                "render": {"status": "notRun"}, "end_to_end_status": "notRun"}
    try:
        manifest, schema = read_json(manifest_path), read_json(schema_path)
        Draft202012Validator.check_schema(schema)
        cases = manifest["cases"]
        if not isinstance(cases, list) or not cases or any(not isinstance(case, dict) for case in cases):
            raise ValueError("manifest cases must be a non-empty list of objects")
        ids = [case.get("id") for case in cases]
        if any(not isinstance(case_id, str) for case_id in ids) or len(set(ids)) != len(ids):
            raise ValueError("case IDs must be unique strings")
    except Exception as error:
        return {"schema_version": 1, "status": "fixtureInvalid", "cases": [],
                "reason": str(error), "render": {"status": "notRun"}, "end_to_end_status": "notRun"}
    # Independent file reads, hashes and response checks overlap, while the
    # separate inference runner keeps large model work serial and memory-bounded.
    with ThreadPoolExecutor(max_workers=min(3, len(cases))) as executor:
        results = list(executor.map(lambda case: evaluate_case(fixtures, responses, case, schema), cases))
    machine_counts = dict(Counter(result["machine_status"] for result in results))
    counts = dict(Counter(result["status"] for result in results))
    machine_passed = machine_counts.get("passed", 0) == len(results)
    if counts.get("fixtureInvalid"):
        status = "fixtureInvalid"
    elif counts.get("missingFixtures"):
        status = "missingFixtures"
    elif counts.get("failed"):
        status = "failed"
    elif counts.get("schemaError"):
        status = "schemaError"
    elif counts.get("abstained"):
        status = "abstained"
    elif counts.get("notRun"):
        status = "notRun"
    else:
        status = "manualReview"
    return {"schema_version": 1, "suite_id": manifest.get("suite_id"), "status": status,
            "contract": {"expectations_sha256": sha256(manifest_path.read_bytes()).hexdigest(),
                         "response_schema_sha256": sha256(schema_path.read_bytes()).hexdigest()},
            "summary": {"case_count": len(results), "status_counts": counts,
                        "machine_status_counts": machine_counts,
                        "all_machine_criteria_passed": machine_passed,
                        "description_reviews_pending": sum(result["manual_review"]["status"] == "manualReview" for result in results)},
            "cases": results, "render": {"status": "notRun"}, "end_to_end_status": "notRun",
            "qualification": "notEstablished",
            "limitations": ["Independent description review is required even when machine criteria pass.",
                            "No corrected image was rendered; no end-to-end photo quality result.",
                            "A small synthetic suite does not establish general photo or 8-GB-device quality."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--responses", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output.resolve().parent == args.fixtures.resolve():
        parser.error("write the report to a separate output directory, not the fixture root")
    report = evaluate_suite(args.fixtures, args.responses)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent, delete=False) as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(args.output)
    print(json.dumps({"status": report["status"], "summary": report.get("summary", {}),
                      "output": str(args.output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

import json
from pathlib import Path
import tempfile
import unittest
from summarize import summarize


class GateSummaryTests(unittest.TestCase):
    def fixture(self, root):
        cases, rows = [], []
        for index in range(20):
            negative = index >= 12
            name = f"positive-{index}" if not negative else f"absent-{index}" if index < 16 else f"multiple-{index}"
            cases.append({"id": name, "negative": negative, "kind": "unsupported" if negative else "sky", "direction": -1})
            runs = [{"pass": phase, "plan": not negative, "target": "sky", "exposure": -1, "iou": 0.9,
                     "error": "unsupportedRequest" if negative else None, "total_ms": 10,
                     "cumulative_process_peak_rss_bytes": 1024, "stages": []}
                    for phase in ("cold-app-cache", "warm-app-cache")]
            if not negative:
                runs.append({"pass": "explicit-reference", "stages": []})
            rows.append({"id": name, "runs": runs})
        report = {"cases": rows, "limits": "test", "qwen_revision": "test", "sky_revision": "test", "subject_revision": "test"}
        (root / "frozen-cases.json").write_text(json.dumps(cases))
        (root / "report.json").write_text(json.dumps(report))
        return report

    def test_two_incorrect_warm_positives_fail_the_gate(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            report = self.fixture(root)
            self.assertEqual(summarize(root)["decision"], "numerical-pass-unqualified")
            for row in report["cases"][:2]:
                row["runs"][1]["exposure"] = 1
            (root / "report.json").write_text(json.dumps(report))
            result = summarize(root)
            self.assertEqual(result["positive_passes_both_caches"], 10)
            self.assertEqual(result["decision"], "NO-GO")

    def test_warm_negative_plan_and_infrastructure_error_are_not_refusals(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            report = self.fixture(root)
            report["cases"][12]["runs"][1]["plan"] = True
            report["cases"][13]["runs"][1]["error"] = "modelNotInstalled"
            (root / "report.json").write_text(json.dumps(report))
            result = summarize(root)
            self.assertEqual(result["negative_refusals_both_caches"], 6)
            self.assertEqual(result["false_positive_negative_plans"], 1)
            self.assertEqual(result["decision"], "NO-GO")

    def test_partial_run_cannot_be_published_as_complete(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            report = self.fixture(root)
            report["cases"].pop()
            (root / "report.json").write_text(json.dumps(report))
            with self.assertRaises(AssertionError):
                summarize(root)

    def test_early_no_go_requires_an_irreversible_failure_bound(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            report = self.fixture(root)
            report["cases"] = report["cases"][:5]
            for row in report["cases"][:2]:
                row["runs"][1]["exposure"] = 1
            (root / "report.json").write_text(json.dumps(report))
            with self.assertRaises(AssertionError):
                summarize(root)
            result = summarize(root, early_no_go=True)
            self.assertEqual(result["decision"], "NO-GO")
            self.assertEqual(result["completed_cases"], 5)
            self.assertEqual(result["maximum_possible_positive_passes"], 10)
            self.assertEqual(len(result["unmeasured_cases"]), 15)
            report["cases"][0]["runs"][1]["exposure"] = -1
            (root / "report.json").write_text(json.dumps(report))
            with self.assertRaises(AssertionError):
                summarize(root, early_no_go=True)

    def test_duplicate_pass_names_are_rejected(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            report = self.fixture(root)
            report["cases"][0]["runs"].append(report["cases"][0]["runs"][0])
            (root / "report.json").write_text(json.dumps(report))
            with self.assertRaises(AssertionError):
                summarize(root)


if __name__ == "__main__":
    unittest.main()

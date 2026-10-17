import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import lc03


class ToneRunnerTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(Path(__file__).with_name("lc03-manifest.json").read_text())
        self.quality = {"records": []}
        for scene in self.manifest["matching"]["sceneClasses"]:
            for direction in self.manifest["directions"]:
                metrics = {"log_line_contrast_error": .2, "bright_line_error": .2, "dark_line_error": .2,
                           "bright_line_count": 10, "dark_line_count": 12}
                self.quality["records"].append({"scene_class": scene, "direction": direction["id"],
                    "primary": direction["primary"], "matched": True, "critical_failures": [],
                    "baseline_metrics": metrics, "candidate_metrics": {**metrics, "log_line_contrast_error": .1,
                                                                        "bright_line_error": .1, "dark_line_error": .1}})

    def primary(self):
        return [r for r in self.quality["records"] if r["scene_class"] == "fine-lines" and r["primary"]]

    def test_synthetic_success_never_invents_visual_or_real_evidence(self):
        decision = lc03.decide(self.quality, self.manifest)
        self.assertEqual(decision["decision"], "blocked")
        self.assertEqual(decision["primary"]["status"], "pass")
        self.assertTrue(any("Licensed real" in s for s in decision["missing_evidence"]))

    def test_matched_critical_failure_is_conclusive_despite_missing_real_photos(self):
        self.quality["records"][0]["critical_failures"] = ["halo undershoot"]
        self.assertEqual(lc03.decide(self.quality, self.manifest)["decision"], "no-go")
        self.quality["records"][0]["matched"] = False
        self.assertEqual(lc03.decide(self.quality, self.manifest)["decision"], "blocked")

    def test_primary_failure_needs_complete_matched_finite_evidence(self):
        for record in self.primary():
            record["candidate_metrics"] = copy.deepcopy(record["baseline_metrics"])
        self.assertEqual(lc03.decide(self.quality, self.manifest)["decision"], "no-go")
        self.primary()[0]["matched"] = False
        self.assertEqual(lc03.decide(self.quality, self.manifest)["decision"], "blocked")
        self.primary()[0]["matched"] = True
        self.primary()[0]["candidate_metrics"]["bright_line_count"] = 0
        self.assertEqual(lc03.decide(self.quality, self.manifest)["primary"]["status"], "blocked")
        self.primary()[0]["candidate_metrics"]["bright_line_count"] = 10
        self.primary()[0]["candidate_metrics"]["log_line_contrast_error"] = float("nan")
        self.assertEqual(lc03.decide(self.quality, self.manifest)["primary"]["status"], "blocked")

    def test_average_gain_cannot_hide_a_region_regression(self):
        self.primary()[0]["candidate_metrics"]["bright_line_error"] = .3
        result = lc03.decide(self.quality, self.manifest)
        self.assertEqual(result["decision"], "no-go")
        self.assertTrue(result["primary"]["regressions"])

    def test_missing_matrix_is_explicit_and_duplicates_are_rejected(self):
        self.quality["records"].pop()
        self.assertIn("Incomplete synthetic acceptance matrix", lc03.decide(self.quality, self.manifest)["missing_evidence"])
        self.quality["records"].append(self.quality["records"][0])
        with self.assertRaises(ValueError):
            lc03.decide(self.quality, self.manifest)

    def test_matching_cannot_admit_opposite_sign_or_neutral_effect(self):
        self.assertTrue(lc03.effect_matches(.01, .011, self.manifest))
        self.assertFalse(lc03.effect_matches(.002, -.0001, self.manifest))
        self.assertFalse(lc03.effect_matches(.001, .001, self.manifest))
        self.assertFalse(lc03.effect_matches(.01, float("nan"), self.manifest))

    def test_performance_veto_is_limited_to_matching_phases(self):
        samples = [{"phase": "process-cold", "total_ms": 1, "effect_strength": .01},
                   {"phase": "warmup", "total_ms": 1, "effect_strength": .01}] + [
                   {"phase": "warm", "total_ms": 1, "effect_strength": .01} for _ in range(5)]
        baseline = {"samples": samples, "input_sha256": "same", "peak_rss_bytes": 100}
        candidate = copy.deepcopy(baseline)
        candidate["peak_rss_bytes"] = 200
        for sample in candidate["samples"]:
            sample["total_ms"] = 10
            if sample["phase"] == "warm":
                sample["effect_strength"] = -.01
        result = lc03.performance_comparison(512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertFalse(result["attributable"])
        self.assertEqual(len(result["budget_exceedances"]), 3)
        self.assertEqual(len(result["failures"]), 1)
        self.assertIn("cold_latency_ratio", result["failures"][0])
        candidate["input_sha256"] = "different"
        with self.assertRaises(ValueError):
            lc03.performance_comparison(512, 320, [baseline] * 5, [candidate] * 5, self.manifest)


if __name__ == "__main__":
    unittest.main()

import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("eigf_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class EIGFDecisionTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(Path(__file__).with_name("manifest.json").read_text())
        self.quality = {"records": []}
        self.calibration = {"records": []}
        for basis in ("simple", "eigf"):
            for scene in self.manifest["sceneClasses"]:
                for d in self.manifest["comparison"]["directions"]:
                    m = {"log_line_contrast_error": .2, "bright_line_error": .2, "dark_line_error": .2,
                         "bright_line_count": 10, "dark_line_count": 12}
                    self.quality["records"].append({"basis": basis, "scene_class": scene, "direction": d["id"],
                        "matched": True, "target": .02, "measured": .02, "critical_failures": [],
                        "parameter": 20,
                        "comparison_metrics": {"alpha_error": 0, "hue_deviation_degrees": 0,
                            "target_gamut_fraction_increase": 0, "target_clipping_fraction_increase": 0,
                            "target_new_gamut_fraction": 0, "target_new_clipping_fraction": 0, "noise_gain_ratio": 1},
                        "baseline_metrics": m, "candidate_metrics": {**m, "log_line_contrast_error": .1,
                            "bright_line_error": .1, "dark_line_error": .1, "halo_overshoot": 0, "halo_undershoot": 0}})
                    self.calibration["records"].append({"basis": basis, "fit": {"sceneClass": scene,
                        "directionID": d["id"], "matched": True, "target": .02, "measured": .02, "parameter": 20}})

    def decide(self, quality=None):
        return runner.decide(quality or self.quality, self.manifest, self.calibration)

    def test_synthetic_success_cannot_grant_production_go(self):
        summary = self.decide()
        self.assertEqual(summary["quality_records"], 192)
        for result in summary["candidates"].values():
            self.assertEqual(result["decision"], "blocked")
            self.assertEqual(result["primary"]["status"], "pass")
            self.assertTrue(result["missing_evidence"])

    def test_candidate_decisions_are_independent_and_matched_veto_is_conclusive(self):
        row = next(r for r in self.quality["records"] if r["basis"] == "eigf" and r["scene_class"] == "ramp")
        row["critical_failures"] = ["target_clipping_fraction_increase"]
        row["comparison_metrics"]["target_clipping_fraction_increase"] = .1
        summary = self.decide()["candidates"]
        self.assertEqual(summary["eigf"]["decision"], "no-go")
        self.assertEqual(summary["simple"]["decision"], "blocked")
        row["matched"] = False; row["measured"] = -.02; row["critical_failures"] = []
        self.assertEqual(self.decide()["candidates"]["eigf"]["decision"], "blocked")

    def test_unmatched_opposite_sign_cannot_claim_pass(self):
        self.quality["records"][0]["measured"] = -.02
        with self.assertRaises(ValueError):
            self.decide()

    def test_duplicates_and_unknown_candidates_fail_closed(self):
        duplicate = copy.deepcopy(self.quality)
        duplicate["records"].append(duplicate["records"][0])
        with self.assertRaises(ValueError):
            self.decide(duplicate)
        self.quality["records"][0]["basis"] = "unknown"
        with self.assertRaises(ValueError):
            self.decide()

    def test_missing_records_and_empty_primary_roi_are_gaps(self):
        self.quality["records"].pop()
        summary = self.decide()["candidates"]
        self.assertIn("Incomplete synthetic acceptance matrix", summary["eigf"]["missing_evidence"])
        row = next(r for r in self.quality["records"] if r["basis"] == "eigf" and r["scene_class"] == "fine-lines")
        row["candidate_metrics"]["bright_line_count"] = 0
        self.assertEqual(self.decide()["candidates"]["eigf"]["primary"]["status"], "blocked")

    def test_numeric_critical_failures_cannot_be_suppressed(self):
        row = self.quality["records"][0]
        row["comparison_metrics"]["alpha_error"] = .1
        with self.assertRaises(ValueError):
            self.decide()
        row["critical_failures"] = ["alpha_error"]
        self.assertEqual(self.decide()["candidates"]["simple"]["decision"], "no-go")

    def test_false_matching_missing_metrics_and_acceptance_refit_fail_closed(self):
        row = self.quality["records"][0]
        row["matched"] = False
        with self.assertRaises(ValueError):
            self.decide()
        row["matched"] = True; row["parameter"] = 21
        with self.assertRaises(ValueError):
            self.decide()
        row["parameter"] = 20; row["comparison_metrics"].pop("alpha_error")
        with self.assertRaises(ValueError):
            self.decide()

    def test_unmatched_effect_cannot_hide_alpha_damage(self):
        row = self.quality["records"][0]
        row["matched"] = False; row["measured"] = -.02
        row["comparison_metrics"]["alpha_error"] = .1
        self.assertEqual(self.decide()["candidates"]["simple"]["decision"], "no-go")


if __name__ == "__main__":
    unittest.main()

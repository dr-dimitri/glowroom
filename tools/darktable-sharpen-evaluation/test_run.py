import copy
import json
from pathlib import Path
import unittest

import run


class SharpenGateTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((Path(__file__).parent / "manifest.json").read_text())
        self.calibration = {"records": []}
        self.quality = {"records": []}
        for variant in run.VARIANTS:
            for c in self.manifest["cases"]:
                self.calibration["records"].append({"variant": variant, "caseID": c["id"], "parameter": 1,
                                                     "target": 0.3, "measured": 0.3, "inputSHA256": "a" * 64})
                for scene in self.manifest["scenes"]:
                    before = {"truth_rmse": 0.02, "detail_contrast": 0.1, "noise_std": 0.004,
                              "alpha_error": 0, "hidden_rgb": 0, "visible_samples": 100,
                              "edge_slope": 0.3, "overshoot": 0.02, "undershoot": 0.01,
                              "halo_total": 0.03, "halo_width_pixels": 5, "edge_rows": 40}
                    after = dict(before, overshoot=0.01, undershoot=0.005, halo_total=0.015, halo_width_pixels=3)
                    self.quality["records"].append({"variant": variant, "case": c["id"], "scene": scene,
                                                    "parameter": 1, "tuning_target": 0.3, "tuning_measured": 0.3,
                                                    "input_sha256": "b" * 64, "truth_sha256": "c" * 64, "output_sha256": "d" * 64,
                                                    "finite": True, "zero_identity": True,
                                                    "baseline_metrics": before, "candidate_metrics": after, "unchanged_metrics": before})

    def decide(self):
        return run.decide(self.calibration, self.quality, self.manifest)

    def test_synthetic_success_cannot_authorize_production(self):
        for decision in self.decide():
            self.assertEqual(decision["status"], "blocked")
            self.assertEqual(decision["primary"]["halo_total"]["status"], "pass")
            self.assertTrue(decision["missing_evidence"])
            self.assertFalse(decision["production_changed"])

    def test_real_regression_is_no_go(self):
        for row in self.quality["records"]:
            row["candidate_metrics"] = copy.deepcopy(row["baseline_metrics"])
        self.assertTrue(all(x["status"] == "no-go" for x in self.decide()))

    def test_weaker_effect_does_not_pass_or_false_no_go(self):
        for row in self.quality["records"]:
            row["candidate_metrics"]["edge_slope"] = 0.25
            row["candidate_metrics"]["noise_std"] = 0.2
        self.assertTrue(all(x["status"] == "blocked" for x in self.decide()))

    def test_missing_or_uninformative_primary_is_blocked(self):
        self.quality["records"].pop()
        self.assertEqual(self.decide()[1]["status"], "blocked")
        self.setUp()
        for row in self.quality["records"]:
            for field in ("baseline_metrics", "candidate_metrics"):
                row[field].update(overshoot=0, undershoot=0, halo_total=0, halo_width_pixels=0)
        self.assertTrue(all(x["status"] == "blocked" for x in self.decide()))

    def test_nonfinite_duplicate_refit_and_empty_support_rejected(self):
        mutations = [lambda q: q["records"].append(q["records"][0]),
                     lambda q: q["records"][0].update(parameter=2),
                     lambda q: q["records"][0]["candidate_metrics"].update(truth_rmse=float("nan")),
                     lambda q: q["records"][0]["candidate_metrics"].update(visible_samples=0)]
        for mutate in mutations:
            q = copy.deepcopy(self.quality); mutate(q)
            with self.assertRaises(ValueError):
                run.decide(self.calibration, q, self.manifest)

    def test_independent_contract_failure_vetoes_even_unmatched(self):
        row = self.quality["records"][0]
        row["candidate_metrics"]["alpha_error"] = 0.1
        row["candidate_metrics"]["edge_slope"] = 0.2
        self.assertEqual(self.decide()[0]["status"], "no-go")

    def test_provenance_and_protocol_tampering_rejected(self):
        with self.assertRaises(ValueError):
            run.validate(self.calibration, self.quality, self.manifest, "e" * 64)
        m = copy.deepcopy(self.manifest)
        m["cases"][2]["id"] = "unexpected"
        with self.assertRaises(ValueError):
            run.validate_protocol(m)
        m = copy.deepcopy(self.manifest)
        m["cases"][2]["radius"] = 3
        with self.assertRaises(ValueError):
            run.validate_protocol(m)

    def timing_rows(self, slope=0.3):
        rows = []
        for width, height in self.manifest["performance"]["sizes"]:
            for adapter in ("glowroom", *run.VARIANTS):
                for process in range(5):
                    phases = ["process-cold", "warmup"] + ["warm"] * 5
                    rows.append({"adapter": adapter, "width": width, "height": height, "process_index": process,
                                 "input_sha256": "e" * 64,
                                 "samples": [{"phase": phase, "ms": 10 if adapter == "glowroom" else 20,
                                              "edge_slope": 0.3 if adapter == "glowroom" else slope,
                                              "peak_rss_bytes": 1000, "output_sha256": "f" * 64} for phase in phases]})
        return rows

    def test_timing_budget_requires_same_pixels_and_matching_effect(self):
        rows = self.timing_rows()
        summary = run.performance_summary(rows, "multiscale", self.manifest)
        self.assertTrue(all(r["status"] == "fail" for r in summary))
        weaker = run.performance_summary(self.timing_rows(0.2), "multiscale", self.manifest)
        self.assertTrue(all(r["status"] == "blocked" for r in weaker))
        rows[0]["input_sha256"] = "1" * 64
        with self.assertRaises(ValueError):
            run.performance_summary(rows, "multiscale", self.manifest)

    def test_missing_timing_matrix_and_scale_never_pass(self):
        self.assertTrue(all(r["status"] == "blocked" for r in run.performance_summary([], "multiscale", self.manifest)))
        self.assertEqual(run.scale_summary(None, "multiscale", self.manifest)["status"], "blocked")
        self.assertEqual(run.scale_summary({"records": []}, "multiscale", self.manifest)["status"], "blocked")

    def test_scale_budget_requires_complete_native_geometry_and_rmse(self):
        rows = [{"adapter": "multiscale", "native_size": self.manifest["scale"]["nativeSize"],
                 "preview_size": size, "native_input_sha256": "a" * 64, "preview_input_sha256": "b" * 64,
                 "scale_rgb_rmse": 0.001} for size in self.manifest["scale"]["previewSizes"]]
        self.assertEqual(run.scale_summary({"records": rows}, "multiscale", self.manifest)["status"], "pass")
        rows[0]["scale_rgb_rmse"] = 0.01
        self.assertEqual(run.scale_summary({"records": rows}, "multiscale", self.manifest)["status"], "fail")
        rows[0]["native_size"] = [512, 341]
        with self.assertRaises(ValueError):
            run.scale_summary({"records": rows}, "multiscale", self.manifest)

    def test_gate_relaxation_requires_new_explicit_protocol(self):
        m = copy.deepcopy(self.manifest)
        m["primary"]["minimumRelativeHaloImprovement"] = 0
        with self.assertRaises(ValueError):
            run.validate_protocol(m)

    def test_matched_per_case_halo_veto_survives_other_unmatched_case(self):
        for row in self.quality["records"]:
            if row["case"] == "wide-100":
                row["candidate_metrics"]["edge_slope"] = 0.2
            if row["case"] == "fine-50" and row["scene"] == "slanted-edge":
                row["candidate_metrics"].update(overshoot=0.04, undershoot=0.01, halo_total=0.05)
        for decision in self.decide():
            self.assertEqual(decision["status"], "no-go")
            self.assertFalse(decision["primary"], "No invalid aggregate across unmatched rows")
            self.assertTrue(any("matched per-case halo_total" in f for f in decision["failures"]))
            self.assertTrue(any("equally steep" in m for m in decision["missing_evidence"]))

    def test_noise_veto_requires_case_matched_on_all_problem_edges(self):
        for row in self.quality["records"]:
            if row["case"] == "wide-100":
                row["candidate_metrics"]["edge_slope"] = 0.2
            if row["case"] == "fine-50" and row["scene"] == "noisy-flat":
                row["candidate_metrics"]["noise_std"] = 0.006
        self.assertTrue(all(x["status"] == "no-go" for x in self.decide()))
        for row in self.quality["records"]:
            if row["case"] == "fine-50" and row["scene"] == "broad-edge":
                row["candidate_metrics"]["edge_slope"] = 0.2
        self.assertTrue(all(x["status"] == "blocked" for x in self.decide()))

    def test_matching_tolerances_are_symmetric_and_positive(self):
        self.assertTrue(run.matched(0.3, 0.306, self.manifest))
        self.assertFalse(run.matched(0.3, 0.29, self.manifest))
        self.assertFalse(run.matched(0, 0, self.manifest))
        self.assertFalse(run.matched(float("nan"), 0.3, self.manifest))


if __name__ == "__main__":
    unittest.main()

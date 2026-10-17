import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import lc06


class DenoiseRunnerTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(Path(__file__).with_name("lc06-manifest.json").read_text())
        self.quality = {"records": [], "zero_diagnostics": []}
        self.calibration = {"records": []}
        for scene in self.manifest["matching"]["sceneClasses"]:
            for direction in self.manifest["directions"]:
                self.quality["records"].append({"scene_class": scene, "direction": direction["id"],
                    "control": direction["control"], "parameter": 35., "matched": True, "tuning_matched": True,
                    "effect_target": .2, "effect_measured": .2, "baseline_metrics": self.metrics(),
                    "candidate_metrics": self.metrics(improved=True), "finite": True, "contract_failures": [],
                    "critical_failures": [], "input_sha256": "a" * 64, "ground_truth_sha256": "c" * 64,
                    "output_sha256": "d" * 64})
                self.calibration["records"].append({"sceneClass": scene, "directionID": direction["id"],
                    "parameter": 35., "target": .2, "measured": .2, "matched": True,
                    "inputSHA256": "b" * 64, "groundTruthSHA256": "c" * 64})
            for control in lc06.CONTROLS:
                for value in self.manifest["contracts"]["neutralValues"]:
                    self.quality["zero_diagnostics"].append({"scene_class": scene, "control": control, "value": value,
                        "input_sha256": "a" * 64, "output_sha256": ("a" if value == 0 else "b") * 64,
                        "identity": value == 0, "metrics": self.metrics(), "finite": True, "contract_failures": []})
        self.scale = {"records": [], "full_size": self.manifest["scaling"]["nativeSize"]}
        for direction in self.manifest["directions"]:
            for width, height in self.manifest["scaling"]["previewSizes"]:
                for variant in self.manifest["scaling"]["variants"]:
                    distance = .0005 if variant == "nativePixels" else .001
                    self.scale["records"].append({"control": direction["control"], "direction": direction["id"],
                        "width": width, "height": height, "variant": variant,
                        "parameter": direction["value"] if variant == "picedit" else 35., "finite": True,
                        "sampling": "areaAveraged", "native_long": 4608, "pixels_per_long_edge": width,
                        "metrics": self.distances(distance), "identity_metrics": self.distances(.002),
                        "quality_metrics": self.metrics(improved=True), "full_quality_metrics": self.metrics(improved=True),
                        "input_sha256": "a" * 64, "ground_truth_sha256": "b" * 64,
                        "full_input_sha256": "c" * 64, "full_ground_truth_sha256": "d" * 64,
                        "full_output_sha256": "e" * 64, "output_sha256": "f" * 64})

    @staticmethod
    def metrics(improved=False):
        return {"noise_luma_rmse": .008, "noise_chroma_rmse": .008,
                "input_noise_luma_rmse": .01, "input_noise_chroma_rmse": .01,
                "noise_luma_reduction": .2, "noise_chroma_reduction": .2,
                "noise_sample_count": 100., "noise_visible_weight": 100.,
                "detail_rgb_rmse": .005 if improved else .01,
                "edge_gradient_rmse": .004 if improved else .008,
                "chroma_fringing_rmse": .001, "detail_sample_count": 100., "detail_visible_weight": 100.,
                "edge_sample_count": 100., "edge_visible_weight": 100., "luma_drift_mean": .001,
                "alpha_error": 0., "hidden_rgb_error": 0., "gamut_fraction": 0., "clipping_fraction": 0.}

    @staticmethod
    def distances(value):
        return {"distance_luma_rmse": value, "distance_chroma_rmse": value, "distance_rgb_rmse": value, "alpha_error": 0.}

    def rows(self, control="luminance", primary=True):
        directions = {d["id"] for d in self.manifest["directions"] if not primary or d["primary"]}
        return [r for r in self.quality["records"] if r["control"] == control and r["direction"] in directions
                and (not primary or r["scene_class"] in self.manifest["primary"]["sceneClasses"])]

    def decide(self, performance=()):
        return lc06.decide(self.quality, self.manifest, performance)

    def test_synthetic_success_is_blocked_for_both_controls_and_scaling(self):
        for value in self.decide().values():
            self.assertEqual(value["decision"], "blocked")
            self.assertEqual(value["primary"]["status"], "pass")
            self.assertEqual(value["quality_records"], 24)
            self.assertEqual(value["contracts"]["zero_diagnostics"], 16)
        scale = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(scale["decision"], "blocked")
        self.assertEqual(scale["records"], 54)
        self.assertTrue(all(p["status"] == "pass" for p in scale["primary"].values()))

    def test_complete_primary_failure_is_control_specific(self):
        for row in self.rows(): row["candidate_metrics"]["detail_rgb_rmse"] = .01
        decision = self.decide()
        self.assertEqual(decision["luminance"]["decision"], "no-go")
        self.assertEqual(decision["chroma"]["decision"], "blocked")

    def test_both_informative_metrics_and_each_case_must_pass(self):
        self.rows()[0]["candidate_metrics"]["edge_gradient_rmse"] = .009
        primary = self.decide()["luminance"]["primary"]
        self.assertEqual(primary["status"], "fail")
        self.assertTrue(primary["metrics"]["edge_gradient_rmse"]["regressions"])
        for row in self.rows(): row["candidate_metrics"]["edge_gradient_rmse"] = .0079
        self.assertEqual(self.decide()["luminance"]["primary"]["status"], "fail")

    def test_no_informative_primary_signal_blocks_without_false_no_go(self):
        for row in self.rows():
            for metrics in (row["baseline_metrics"], row["candidate_metrics"]):
                metrics.update(detail_rgb_rmse=0., edge_gradient_rmse=0.)
        result = self.decide()["luminance"]
        self.assertEqual(result["primary"]["status"], "blocked")
        self.assertEqual(result["decision"], "blocked")

    def test_missing_matching_support_and_rows_block_primary(self):
        row = self.rows()[0]
        row["tuning_matched"] = False
        self.assertEqual(self.decide()["luminance"]["primary"]["status"], "blocked")
        row["tuning_matched"] = True
        row["candidate_metrics"]["edge_sample_count"] = 0.
        self.assertEqual(self.decide()["luminance"]["primary"]["status"], "blocked")
        self.quality["records"].remove(row)
        self.assertEqual(self.decide()["luminance"]["primary"]["status"], "blocked")

    def test_critical_metrics_are_recomputed_and_unmatched_cannot_veto(self):
        row = self.rows()[0]
        row["candidate_metrics"]["clipping_fraction"] = .03
        self.assertEqual(self.decide()["luminance"]["decision"], "no-go")
        row["matched"] = False
        self.assertEqual(self.decide()["luminance"]["decision"], "blocked")
        row["matched"] = True
        row["candidate_metrics"]["clipping_fraction"] = 0.
        row["critical_failures"] = ["clipping_fraction"]
        self.assertEqual(self.decide()["luminance"]["decision"], "blocked")

    def test_contracts_veto_without_matching(self):
        row = self.rows()[0]
        row["matched"] = False
        row["candidate_metrics"]["hidden_rgb_error"] = 1e-12
        self.assertEqual(self.decide()["luminance"]["decision"], "no-go")
        row["candidate_metrics"]["hidden_rgb_error"] = 0.
        row["candidate_metrics"]["alpha_error"] = .002
        self.assertEqual(self.decide()["luminance"]["decision"], "no-go")
        row["candidate_metrics"]["alpha_error"] = float("nan")
        with self.assertRaises(ValueError): self.decide()

    def test_exact_zero_contract_and_missing_matrix(self):
        row = self.quality["zero_diagnostics"][0]
        row.update(output_sha256="b" * 64, identity=False)
        self.assertEqual(self.decide()[row["control"]]["decision"], "no-go")
        row["identity"] = True
        with self.assertRaises(ValueError): self.decide()
        self.quality["zero_diagnostics"].remove(row)
        self.assertEqual(self.decide()[row["control"]]["contracts"]["status"], "blocked")

    def test_unknown_duplicate_and_wrong_control_are_rejected(self):
        original = copy.deepcopy(self.quality)
        self.quality["records"].append(self.quality["records"][0])
        with self.assertRaises(ValueError): self.decide()
        self.quality = copy.deepcopy(original)
        self.quality["records"][0]["control"] = "chroma"
        with self.assertRaises(ValueError): self.decide()
        self.quality = original
        self.quality["zero_diagnostics"].append(self.quality["zero_diagnostics"][0])
        with self.assertRaises(ValueError): self.decide()

    def test_positive_reduction_matching_rejects_neutral_and_amplification(self):
        self.assertTrue(lc06.reduction_matches(.2, .205, self.manifest))
        for target, measured in ((0, 0), (-.2, -.2), (.2, -.2), (.0001, .0001), (.2, .22)):
            self.assertFalse(lc06.reduction_matches(target, measured, self.manifest))

    def test_strength_must_agree_with_measured_ground_truth_rmse(self):
        row = self.rows()[0]
        row["candidate_metrics"]["noise_luma_rmse"] = .005
        with self.assertRaises(ValueError): self.decide()
        row["candidate_metrics"]["noise_luma_reduction"] = .5
        with self.assertRaises(ValueError): self.decide()
        row["effect_measured"] = .5
        self.assertEqual(self.decide()["luminance"]["decision"], "blocked")

    def test_calibration_is_complete_frozen_and_uses_independent_noise(self):
        lc06.validate_calibration(self.calibration, self.manifest, self.quality)
        row = self.quality["records"][0]
        for key, value in (("parameter", 36.), ("input_sha256", "b" * 64),
                           ("ground_truth_sha256", "f" * 64), ("tuning_matched", False)):
            before = row[key]; row[key] = value
            with self.assertRaises(ValueError): lc06.validate_calibration(self.calibration, self.manifest, self.quality)
            row[key] = before
        self.calibration["records"].pop()
        with self.assertRaises(ValueError): lc06.validate_calibration(self.calibration, self.manifest)

    @staticmethod
    def timing(adapter="picedit", control="luminance"):
        return {"width": 512, "height": 320, "adapter": f"{adapter}-{control}", "control": control,
                "samples": [{"phase": phase, "total_ms": 1., "effect_strength": .2}
                            for phase in ["process-cold", "warmup"] + ["warm"] * 5],
                "input_sha256": "a" * 64, "ground_truth_sha256": "b" * 64, "peak_rss_bytes": 100}

    def test_timing_veto_requires_its_phase_and_correct_control(self):
        baseline, candidate = self.timing(), self.timing("lightcraft")
        candidate["peak_rss_bytes"] = 200
        for sample in candidate["samples"]:
            sample["total_ms"] = 2.
            if sample["phase"] == "warm": sample["effect_strength"] = -.2
        result = lc06.performance_comparison("luminance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertEqual(len(result["failures"]), 1)
        self.assertIn("cold_latency_ratio", result["failures"][0])
        self.assertEqual(self.decide([result])["luminance"]["decision"], "no-go")
        self.assertEqual(self.decide([result])["chroma"]["decision"], "blocked")

    def test_timing_rejects_geometry_schedule_and_ground_truth_changes(self):
        baseline = self.timing()
        for key, value in (("width", 2400), ("control", "chroma"), ("ground_truth_sha256", "c" * 64), ("peak_rss_bytes", 0)):
            candidate = self.timing("lightcraft"); candidate[key] = value
            with self.assertRaises(ValueError):
                lc06.performance_comparison("luminance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        candidate = self.timing("lightcraft")
        candidate["samples"].append({"phase": "unexpected", "total_ms": 1., "effect_strength": .2})
        with self.assertRaises(ValueError):
            lc06.performance_comparison("luminance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)

    def scale_row(self, control="luminance", variant="nativePixels"):
        return next(r for r in self.scale["records"] if r["control"] == control and r["variant"] == variant)

    def test_scaling_decision_cannot_borrow_formula_or_other_control_success(self):
        for row in self.scale["records"]:
            if row["control"] == "chroma" and row["variant"] == "nativePixels":
                row["metrics"]["distance_chroma_rmse"] = .001
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["decision"], "no-go")
        self.assertEqual(result["primary"]["luminance"]["status"], "pass")
        self.assertEqual(result["primary"]["chroma"]["status"], "fail")
        self.assertEqual(self.decide()["chroma"]["decision"], "blocked")

    def test_scaling_zero_distance_signal_is_blocked_not_false_no_go(self):
        for row in self.scale["records"]: row["metrics"] = self.distances(0.)
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["decision"], "blocked")
        self.assertTrue(all(r["status"] == "blocked" for r in result["primary"].values()))

    def test_scaling_no_op_preview_cannot_pass_via_small_distance(self):
        row = self.scale_row()
        row["quality_metrics"].update(noise_luma_rmse=.01, noise_luma_reduction=0.)
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["decision"], "no-go")
        self.assertTrue(any("preview_noise_reduction" in value for value in result["critical_failures"]))

    def test_scaling_quality_and_absolute_distance_guards(self):
        row = self.scale_row()
        row["quality_metrics"]["edge_gradient_rmse"] = .007
        self.assertEqual(lc06.scaling_decision(self.scale, self.manifest)["decision"], "no-go")
        row["quality_metrics"]["edge_gradient_rmse"] = .004
        row["metrics"]["distance_luma_rmse"] = .0021
        self.assertEqual(lc06.scaling_decision(self.scale, self.manifest)["decision"], "no-go")

    def test_scaling_diagnostic_picedit_cannot_veto_native_scaling(self):
        row = self.scale_row(variant="picedit")
        row["quality_metrics"].update(edge_gradient_rmse=1., alpha_error=1.)
        row["metrics"] = self.distances(1.)
        self.assertEqual(lc06.scaling_decision(self.scale, self.manifest)["decision"], "blocked")

    def test_scaling_requires_explicit_finite_output_evidence(self):
        row = self.scale_row()
        row["finite"] = False
        with self.assertRaises(ValueError): lc06.scaling_decision(self.scale, self.manifest)
        row.pop("finite")
        with self.assertRaises(ValueError): lc06.scaling_decision(self.scale, self.manifest)

    def test_scaling_contract_failure_survives_missing_comparison_records(self):
        candidate = self.scale_row()
        candidate["quality_metrics"]["alpha_error"] = .002
        self.scale["records"].remove(self.scale_row(variant="picedit"))
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["decision"], "no-go")
        self.assertEqual(result["primary"]["luminance"]["status"], "blocked")
        candidate["quality_metrics"]["alpha_error"] = 0.
        candidate["quality_metrics"]["hidden_rgb_error"] = 1e-12
        self.scale["records"].remove(self.scale_row(variant="unscaled"))
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["decision"], "no-go")
        self.assertTrue(any("hidden_rgb_error" in item for item in result["critical_failures"]))

    def test_scaling_rejects_confounded_parameters_inputs_and_geometry(self):
        row = self.scale_row()
        for key, value in (("parameter", 36.), ("input_sha256", "f" * 64), ("full_output_sha256", "f" * 64),
                           ("sampling", "unknown"), ("native_long", 512)):
            before = row[key]; row[key] = value
            with self.assertRaises(ValueError): lc06.scaling_decision(self.scale, self.manifest)
            row[key] = before

    def test_scaling_uses_the_frozen_calibration_at_every_size(self):
        lc06.validate_scaling_calibration(self.scale, self.calibration, self.manifest)
        self.scale_row()["parameter"] = 36.
        with self.assertRaises(ValueError): lc06.validate_scaling_calibration(self.scale, self.calibration, self.manifest)

    def test_missing_or_duplicate_scaling_evidence_cannot_pass(self):
        row = self.scale["records"].pop()
        result = lc06.scaling_decision(self.scale, self.manifest)
        self.assertEqual(result["primary"]["chroma"]["status"], "blocked")
        self.scale["records"].append(self.scale["records"][0])
        with self.assertRaises(ValueError): lc06.scaling_decision(self.scale, self.manifest)

    def test_views_reject_path_traversal(self):
        with tempfile.TemporaryDirectory() as path:
            with self.assertRaises(ValueError): lc06.views(Path(path), [{"directory": "../../outside"}])


if __name__ == "__main__":
    unittest.main()

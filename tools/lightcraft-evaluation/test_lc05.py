import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import lc05


class ColorRunnerTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(Path(__file__).with_name("lc05-manifest.json").read_text())
        self.quality = {"records": [], "zero_diagnostics": [], "full_desaturation_diagnostics": []}
        for scene in self.manifest["matching"]["sceneClasses"]:
            for direction in self.manifest["directions"]:
                sign = 1 if direction["value"] > 0 else -1
                for variant in lc05.VARIANTS:
                    self.quality["records"].append({"scene_class": scene, "direction": direction["id"],
                        "control": direction["control"], "variant": variant, "matched": True,
                        "effect_target": sign * .01, "effect_measured": sign * .0101,
                        "finite": True, "contract_failures": [], "critical_failures": [],
                        "baseline_metrics": self.metrics(), "candidate_metrics": self.metrics(improved=True),
                        "compatibility_metrics": {"hue_deviation_degrees": 100}})
            for variant in lc05.VARIANTS:
                self.quality["full_desaturation_diagnostics"].append({"scene_class": scene, "variant": variant,
                    "finite": True, "metrics": self.metrics(improved=True), "contract_failures": []})
                for control in lc05.CONTROLS:
                    for value in (-1, 0, 1):
                        self.quality["zero_diagnostics"].append({"scene_class": scene, "control": control,
                            "variant": variant, "value": value, "input_sha256": "a" * 64,
                            "output_sha256": "a" * 64 if value == 0 else "b" * 64, "identity": value == 0,
                            "finite": True, "metrics": self.metrics(improved=True), "contract_failures": []})

    @staticmethod
    def metrics(improved=False):
        return {"hue_drift_mean_degrees": .5 if improved else 1., "hue_drift_max_degrees": 1. if improved else 2.,
                "lightness_drift_mean": .005 if improved else .01, "visible_weight": 100.,
                "hue_sample_count": 100., "hue_missing_count": 0., "hue_loss_fraction": 0.,
                "gamut_fraction": 0., "clipping_fraction": 0., "alpha_error": 0.,
                "output_chroma_max": 0., "neutral_chroma_max": 0., "neutral_sample_count": 20., "hidden_rgb_error": 0.,
                "gradation_sample_count": 100., "gradation_collapse_fraction": 0., "gradation_reversal_fraction": 0.}

    def rows(self, control="vibrance", variant=lc05.CANDIDATE, primary=True):
        directions = {d["id"] for d in self.manifest["directions"] if d["primary"] or not primary}
        return [r for r in self.quality["records"] if r["control"] == control and r["variant"] == variant
                and (not primary or r["scene_class"] in self.manifest["primary"]["sceneClasses"])
                and r["direction"] in directions]

    def decide(self, performance=()):
        return lc05.decide(self.quality, self.manifest, performance)

    def test_synthetic_success_cannot_authorize_production(self):
        decisions = self.decide()
        for value in decisions.values():
            self.assertEqual(value["decision"], "blocked")
            self.assertEqual(value["primary"]["status"], "pass")
            self.assertTrue(any("Licensed" in item for item in value["missing_evidence"]))
        self.assertEqual(decisions["vibrance"]["quality_records"], 108)
        self.assertEqual(decisions["saturation"]["contracts"]["full_desaturation_diagnostics"], 18)

    def test_input_relative_metrics_override_diagnostic_compatibility(self):
        self.assertEqual(self.decide()["vibrance"]["primary"]["status"], "pass")
        for row in self.rows():
            row["candidate_metrics"]["hue_drift_mean_degrees"] = 1.
            row["compatibility_metrics"]["hue_deviation_degrees"] = 0.
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        self.assertEqual(self.decide()["saturation"]["decision"], "blocked")

    def test_unbounded_diagnostic_regressions_cannot_veto_mapped_candidate(self):
        for row in self.rows(variant="unbounded", primary=False):
            row["candidate_metrics"].update(hue_drift_mean_degrees=20., gamut_fraction=1., neutral_chroma_max=.1)
            row["critical_failures"] = ["hue_drift_max_degrees"]
            row["contract_failures"] = ["neutral_chroma_max"]
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")
        self.assertTrue(self.decide()["vibrance"]["contracts"]["diagnostic_failures"])

    def test_critical_regression_is_recomputed_and_control_specific(self):
        row = self.rows()[0]
        row["candidate_metrics"]["hue_drift_max_degrees"] = 6.
        row["critical_failures"] = []
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        self.assertEqual(self.decide()["saturation"]["decision"], "blocked")
        row["matched"] = False
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")

    def test_unsubstantiated_native_critical_label_does_not_create_veto(self):
        self.rows()[0]["critical_failures"] = ["hue_drift_max_degrees"]
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")

    def test_missing_critical_evidence_does_not_pass(self):
        self.rows()[0]["candidate_metrics"].pop("hue_drift_max_degrees")
        self.assertTrue(any("missing critical evidence" in item for item in self.decide()["vibrance"]["missing_evidence"]))

    def test_native_match_flag_cannot_override_wrong_sign(self):
        row = self.rows()[0]
        row["candidate_metrics"]["hue_drift_max_degrees"] = 6.
        row["effect_measured"] *= -1
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")

    def test_incomplete_primary_and_lost_hue_support_block_primary(self):
        row = self.rows()[0]
        row["candidate_metrics"]["hue_missing_count"] = 1
        self.assertEqual(self.decide()["vibrance"]["primary"]["status"], "blocked")
        row["candidate_metrics"]["hue_missing_count"] = 0
        row["baseline_metrics"]["hue_sample_count"] = 0
        self.assertEqual(self.decide()["vibrance"]["primary"]["status"], "blocked")
        self.quality["records"].remove(row)
        self.assertEqual(self.decide()["vibrance"]["primary"]["status"], "blocked")

    def test_floor_target_needs_no_regression_and_an_informative_gain(self):
        for row in self.rows():
            row["baseline_metrics"]["hue_drift_mean_degrees"] = .01
            row["candidate_metrics"]["hue_drift_mean_degrees"] = .04
        primary = self.decide()["vibrance"]["primary"]
        self.assertEqual(primary["status"], "pass")
        self.assertIsNone(primary["metrics"]["hue_drift_mean_degrees"]["relative_improvement"])
        for row in self.rows():
            row["candidate_metrics"]["hue_drift_mean_degrees"] = .051
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        for row in self.rows():
            row["candidate_metrics"]["hue_drift_mean_degrees"] = .01
            row["baseline_metrics"]["lightness_drift_mean"] = 0.
            row["candidate_metrics"]["lightness_drift_mean"] = 0.
        self.assertEqual(self.decide()["vibrance"]["primary"]["informative_targets"], 0)
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")

    def test_aggregate_gain_cannot_hide_a_primary_class_regression(self):
        self.rows()[0]["candidate_metrics"]["hue_drift_mean_degrees"] = 1.3
        decision = self.decide()["vibrance"]
        self.assertEqual(decision["decision"], "no-go")
        self.assertTrue(decision["primary"]["metrics"]["hue_drift_mean_degrees"]["regressions"])

    def test_both_informative_objectives_must_improve(self):
        for row in self.rows():
            row["candidate_metrics"]["lightness_drift_mean"] = .0095
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")

    def test_neutral_identity_is_independent_of_effect_matching(self):
        row = next(r for r in self.quality["zero_diagnostics"] if r["control"] == "saturation" and r["variant"] == lc05.CANDIDATE and r["value"] == 0)
        row.update(output_sha256="b" * 64, identity=False)
        self.assertEqual(self.decide()["saturation"]["decision"], "no-go")
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")
        row["identity"] = True
        with self.assertRaises(ValueError):
            self.decide()

    def test_alpha_gray_and_finite_contracts_cannot_disappear_when_unmatched(self):
        row = self.rows()[0]
        row["matched"] = False
        row["candidate_metrics"]["neutral_chroma_max"] = .0001
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        row["candidate_metrics"]["neutral_chroma_max"] = 0.
        row["candidate_metrics"]["alpha_error"] = .002
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        row["candidate_metrics"]["alpha_error"] = float("nan")
        with self.assertRaises(ValueError):
            self.decide()

    def test_hidden_rgb_error_is_an_independent_contract_failure(self):
        row = self.rows()[0]
        row["matched"] = False
        row["candidate_metrics"]["hidden_rgb_error"] = 1e-10
        self.assertEqual(self.decide()["vibrance"]["decision"], "no-go")
        self.assertEqual(self.decide()["saturation"]["decision"], "blocked")

    def test_missing_contract_fields_are_invalid_not_success(self):
        self.rows()[0].pop("contract_failures")
        with self.assertRaises(ValueError):
            self.decide()

    def test_saturation_minus100_has_achromatic_contract_and_no_hue_veto(self):
        for row in self.rows("saturation", primary=False):
            if row["direction"] == "saturation-negative-100":
                row["candidate_metrics"].update(hue_drift_max_degrees=180., hue_loss_fraction=1.,
                                                gradation_collapse_fraction=1., gradation_reversal_fraction=1.)
        self.assertEqual(self.decide()["saturation"]["decision"], "blocked")
        row = next(r for r in self.quality["full_desaturation_diagnostics"] if r["variant"] == lc05.CANDIDATE)
        row["metrics"]["output_chroma_max"] = .0001
        self.assertEqual(self.decide()["saturation"]["decision"], "no-go")
        self.assertEqual(self.decide()["vibrance"]["decision"], "blocked")

    def test_missing_or_duplicate_contract_matrix_is_visible(self):
        self.quality["full_desaturation_diagnostics"].pop()
        self.assertEqual(self.decide()["saturation"]["contracts"]["status"], "blocked")
        self.quality["zero_diagnostics"].append(self.quality["zero_diagnostics"][0])
        with self.assertRaises(ValueError):
            self.decide()

    def test_duplicate_quality_unknown_variant_and_wrong_control_are_rejected(self):
        original = copy.deepcopy(self.quality)
        self.quality["records"].append(self.quality["records"][0])
        with self.assertRaises(ValueError): self.decide()
        self.quality = copy.deepcopy(original)
        self.quality["records"][0]["variant"] = "invented"
        with self.assertRaises(ValueError): self.decide()
        self.quality = original
        self.quality["records"][0]["control"] = "saturation"
        with self.assertRaises(ValueError): self.decide()

    @staticmethod
    def timing(adapter="picedit", control="vibrance"):
        return {"width": 512, "height": 320, "adapter": f"{adapter}-{control}", "control": control,
                "samples": [{"phase": phase, "total_ms": 1., "effect_strength": .01}
                            for phase in ["process-cold", "warmup"] + ["warm"] * 5],
                "input_sha256": "a" * 64, "peak_rss_bytes": 100}

    def test_performance_veto_is_phase_specific_and_control_specific(self):
        baseline, candidate = self.timing(), self.timing("lightcraft")
        candidate["peak_rss_bytes"] = 200
        for sample in candidate["samples"]:
            sample["total_ms"] = 10.
            if sample["phase"] == "warm": sample["effect_strength"] *= -1
        summary = lc05.performance_comparison("vibrance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertEqual(len(summary["failures"]), 1)
        self.assertIn("cold_latency_ratio", summary["failures"][0])
        self.assertEqual(self.decide([summary])["vibrance"]["decision"], "no-go")
        self.assertEqual(self.decide([summary])["saturation"]["decision"], "blocked")
        candidate["samples"][0]["effect_strength"] = 0.
        summary = lc05.performance_comparison("vibrance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertEqual(summary["failures"], [])
        self.assertEqual(self.decide([summary])["vibrance"]["decision"], "blocked")

    def test_timing_rejects_metadata_input_process_schedule_or_rss_mismatch(self):
        baseline = self.timing()
        for key, value in (("width", 2400), ("control", "saturation"), ("adapter", "picedit-vibrance"),
                           ("input_sha256", "different"), ("peak_rss_bytes", float("nan"))):
            candidate = self.timing("lightcraft"); candidate[key] = value
            with self.assertRaises(ValueError):
                lc05.performance_comparison("vibrance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        candidate = self.timing("lightcraft")
        with self.assertRaises(ValueError):
            lc05.performance_comparison("vibrance", 512, 320, [baseline] * 5, [candidate] * 6, self.manifest)
        candidate["samples"][0], candidate["samples"][1] = candidate["samples"][1], candidate["samples"][0]
        with self.assertRaises(ValueError):
            lc05.performance_comparison("vibrance", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)

    def test_signed_matching_rejects_neutral_wrong_sign_and_loose_small_target(self):
        self.assertTrue(lc05.effect_matches(.01, .0104, self.manifest))
        for before, after in ((0., 0.), (.01, -.01), (.0001, .0001), (.0002, .0012), (.01, float("nan"))):
            self.assertFalse(lc05.effect_matches(before, after, self.manifest))

    def test_path_traversal_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as path:
            with self.assertRaises(ValueError): lc05.views(Path(path), [{"directory": "../../outside"}])


if __name__ == "__main__":
    unittest.main()

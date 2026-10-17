import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import lc04


class DetailRunnerTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(Path(__file__).with_name("lc04-manifest.json").read_text())
        self.quality = {"records": [], "zero_diagnostics": []}
        for scene in self.manifest["matching"]["sceneClasses"]:
            for control, variants in lc04.VARIANTS.items():
                for variant in variants:
                    for value in (-1, 0, 1):
                        self.quality["zero_diagnostics"].append({"scene_class": scene, "control": control,
                            "variant": variant, "value": value, "input_sha256": "a" * 64,
                            "output_sha256": "a" * 64 if value == 0 else "b" * 64, "identity": value == 0})
        for scene in self.manifest["matching"]["sceneClasses"]:
            for direction in self.manifest["directions"]:
                sign = 1 if direction["value"] > 0 else -1
                for variant in lc04.VARIANTS[direction["control"]]:
                    metrics = {"halo_area": .2, "halo_sample_count": 100, "halo_dark_sample_count": 50, "halo_bright_sample_count": 50, "noise_amplification": 1., "noise_sample_count": 100}
                    is_candidate = variant == lc04.CANDIDATES[direction["control"]]
                    self.quality["records"].append({"fixture": scene + "-acceptance", "scene_class": scene,
                        "direction": direction["id"], "control": direction["control"], "variant": variant,
                        "primary": direction["primary"], "matched": True, "effect_target": sign * .01,
                        "effect_measured": sign * .0101, "critical_failures": [], "baseline_metrics": metrics,
                        "candidate_metrics": {**metrics, "halo_area": .1 if is_candidate else .18}})

    def primary(self, control="clarity", variant=None):
        variant = variant or lc04.CANDIDATES[control]
        return [r for r in self.quality["records"] if r["control"] == control and r["primary"]
                and r["scene_class"] in self.manifest["primary"]["sceneClasses"] and r["variant"] == variant]

    def decide(self, performance=()):
        return lc04.decide(self.quality, self.manifest, performance)

    def test_synthetic_success_never_invents_visual_or_real_evidence(self):
        decisions = self.decide()
        for control in lc04.CANDIDATES:
            self.assertEqual(decisions[control]["decision"], "blocked")
            self.assertEqual(decisions[control]["primary"]["status"], "pass")
            self.assertTrue(any("Licensed real" in s for s in decisions[control]["missing_evidence"]))

    def test_clarity_and_texture_have_independent_decisions(self):
        self.primary()[0]["critical_failures"] = ["edge overshoot"]
        self.assertEqual(self.decide()["clarity"]["decision"], "no-go")
        self.assertEqual(self.decide()["texture"]["decision"], "blocked")
        self.primary()[0]["matched"] = False
        self.assertEqual(self.decide()["clarity"]["decision"], "blocked")

    def test_ablation_critical_failure_cannot_veto_production_candidate(self):
        row = self.primary("clarity", "clarityGaussianLog")[0]
        row["critical_failures"] = ["diagnostic Gaussian regression"]
        self.assertEqual(self.decide()["clarity"]["decision"], "blocked")

    def test_native_matching_boolean_does_not_override_wrong_signed_effect(self):
        row = self.primary()[0]
        row["critical_failures"] = ["edge overshoot"]
        row["effect_measured"] = -row["effect_target"]
        self.assertEqual(self.decide()["clarity"]["decision"], "blocked")
        row["effect_measured"] = float("nan")
        self.assertEqual(self.decide()["clarity"]["decision"], "blocked")

    def test_primary_failure_needs_complete_finite_nonempty_matched_evidence(self):
        for row in self.primary():
            row["candidate_metrics"]["halo_area"] = .2
        self.assertEqual(self.decide()["clarity"]["decision"], "no-go")
        row = self.primary()[0]
        row["matched"] = False
        self.assertEqual(self.decide()["clarity"]["decision"], "blocked")
        row["matched"] = True
        row["candidate_metrics"]["halo_sample_count"] = 0
        self.assertEqual(self.decide()["clarity"]["primary"]["status"], "blocked")
        row["candidate_metrics"]["halo_sample_count"] = 10
        row["candidate_metrics"]["halo_area"] = float("nan")
        self.assertEqual(self.decide()["clarity"]["primary"]["status"], "blocked")

    def test_bright_side_alone_cannot_prove_halo_gain(self):
        self.primary()[0]["candidate_metrics"]["halo_dark_sample_count"] = 0
        self.assertEqual(self.decide()["clarity"]["primary"]["status"], "blocked")

    def test_average_gain_cannot_hide_scene_direction_regression(self):
        self.primary()[0]["candidate_metrics"]["halo_area"] = .23
        decision = self.decide()["clarity"]
        self.assertEqual(decision["decision"], "no-go")
        self.assertTrue(decision["primary"]["regressions"])

    def test_texture_requires_benefit_over_same_gaussian_existing_domain(self):
        for row in self.primary("texture", "textureGaussianExistingDomain"):
            row["candidate_metrics"]["halo_area"] = .1
        decisions = self.decide()
        self.assertEqual(decisions["texture"]["decision"], "no-go")
        self.assertEqual(decisions["texture"]["primary"]["status"], "pass")
        self.assertEqual(decisions["clarity"]["decision"], "blocked")
        self.primary("texture", "textureGaussianExistingDomain")[0]["matched"] = False
        self.assertEqual(self.decide()["texture"]["decision"], "blocked")

    def test_limiter_incremental_result_remains_explicit(self):
        row = self.decide()["texture"]["ablations"]["textureGaussianLog"]
        self.assertEqual(row["status"], "pass")
        self.assertFalse(row["required_for_adoption"])

    def test_missing_matrix_and_missing_primary_are_explicit(self):
        self.quality["records"].pop()
        self.assertIn("Incomplete synthetic acceptance and ablation matrix", self.decide()["texture"]["missing_evidence"])
        self.quality["records"].remove(self.primary()[0])
        self.assertEqual(self.decide()["clarity"]["primary"]["status"], "blocked")

    def test_duplicates_unknown_variants_and_mislabelled_controls_are_rejected(self):
        original = copy.deepcopy(self.quality)
        self.quality["records"].append(self.quality["records"][0])
        with self.assertRaises(ValueError):
            self.decide()
        self.quality = copy.deepcopy(original)
        self.quality["records"][0]["variant"] = "invented"
        with self.assertRaises(ValueError):
            self.decide()
        self.quality = original
        self.quality["records"][0]["control"] = "texture"
        with self.assertRaises(ValueError):
            self.decide()

    def test_neutral_identity_regression_rejects_only_affected_control(self):
        row = next(r for r in self.quality["zero_diagnostics"] if r["value"] == 0 and r["variant"] == "clarityGuidedLog")
        row.update(output_sha256="b" * 64, identity=False)
        decisions = self.decide()
        self.assertEqual(decisions["clarity"]["decision"], "no-go")
        self.assertEqual(decisions["clarity"]["neutral_identity"]["status"], "fail")
        self.assertEqual(decisions["texture"]["decision"], "blocked")

    def test_missing_zero_transition_records_block_identity_approval(self):
        self.assertEqual(self.decide()["clarity"]["neutral_identity"]["status"], "pass")
        self.quality["zero_diagnostics"].pop(0)
        self.assertEqual(self.decide()["clarity"]["neutral_identity"]["status"], "blocked")
        self.assertTrue(any("transition" in s for s in self.decide()["clarity"]["missing_evidence"]))
        self.quality.pop("zero_diagnostics")
        self.assertEqual(self.decide()["texture"]["neutral_identity"]["status"], "blocked")

    def test_zero_transition_provenance_cannot_claim_identity_incorrectly(self):
        row = next(r for r in self.quality["zero_diagnostics"] if r["value"] == 0)
        row["identity"] = False
        with self.assertRaises(ValueError):
            self.decide()
        row["identity"] = True
        row["input_sha256"] = "invalid"
        with self.assertRaises(ValueError):
            self.decide()

    def test_duplicate_zero_transition_diagnostic_is_rejected(self):
        self.quality["zero_diagnostics"].append(self.quality["zero_diagnostics"][0])
        with self.assertRaises(ValueError):
            self.decide()

    def test_matching_rejects_neutral_small_opposite_and_nonfinite_effects(self):
        self.assertTrue(lc04.effect_matches(.01, .0104, self.manifest))
        for target, measured in ((.01, -.01), (0, 0), (.0001, .0001), (.0002, .0012), (.01, .0106), (.01, float("nan")), (True, 1)):
            self.assertFalse(lc04.effect_matches(target, measured, self.manifest))

    @staticmethod
    def run_data():
        return {"samples": [{"phase": "process-cold", "total_ms": 1, "effect_strength": .01},
                            {"phase": "warmup", "total_ms": 1, "effect_strength": .01}] +
                           [{"phase": "warm", "total_ms": 1, "effect_strength": .01} for _ in range(5)],
                "input_sha256": "same", "peak_rss_bytes": 100}

    def test_performance_veto_only_uses_matching_phases(self):
        baseline = self.run_data()
        candidate = copy.deepcopy(baseline)
        candidate["peak_rss_bytes"] = 200
        for sample in candidate["samples"]:
            sample["total_ms"] = 10
            if sample["phase"] == "warm":
                sample["effect_strength"] = -.01
        comparison = lc04.performance_comparison("texture", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertFalse(comparison["attributable"])
        self.assertEqual(len(comparison["budget_exceedances"]), 3)
        self.assertEqual(len(comparison["failures"]), 1)
        self.assertIn("cold_latency_ratio", comparison["failures"][0])
        decisions = self.decide([comparison])
        self.assertEqual(decisions["texture"]["decision"], "no-go")
        self.assertEqual(decisions["clarity"]["decision"], "blocked")
        candidate["samples"][0]["effect_strength"] = 0
        comparison = lc04.performance_comparison("texture", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        self.assertEqual(comparison["failures"], [])
        self.assertEqual(self.decide([comparison])["texture"]["decision"], "blocked")

    def test_performance_rejects_different_inputs_process_counts_and_phases(self):
        baseline = self.run_data()
        candidate = copy.deepcopy(baseline)
        candidate["input_sha256"] = "different"
        with self.assertRaises(ValueError):
            lc04.performance_comparison("clarity", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)
        candidate["input_sha256"] = "same"
        with self.assertRaises(ValueError):
            lc04.performance_comparison("clarity", 512, 320, [baseline] * 5, [candidate] * 6, self.manifest)
        candidate["samples"][0], candidate["samples"][1] = candidate["samples"][1], candidate["samples"][0]
        with self.assertRaises(ValueError):
            lc04.performance_comparison("clarity", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)

    def test_performance_rejects_nonfinite_memory(self):
        baseline = self.run_data()
        candidate = copy.deepcopy(baseline)
        candidate["peak_rss_bytes"] = float("nan")
        with self.assertRaises(ValueError):
            lc04.performance_comparison("clarity", 512, 320, [baseline] * 5, [candidate] * 5, self.manifest)

    def test_later_nonfinite_rss_cannot_be_hidden_by_maximum_aggregation(self):
        baseline = self.run_data()
        candidate_runs = [copy.deepcopy(baseline) for _ in range(5)]
        candidate_runs[-1]["peak_rss_bytes"] = float("nan")
        with self.assertRaises(ValueError):
            lc04.performance_comparison("clarity", 512, 320, [baseline] * 5, candidate_runs, self.manifest)

    def test_views_reject_path_escape_before_copying(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                lc04.views(Path(directory), [{"directory": "../../outside"}])


if __name__ == "__main__":
    unittest.main()

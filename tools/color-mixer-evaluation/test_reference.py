import copy
import json
import math
from pathlib import Path
import unittest
import evaluate
import generate_fixtures
import reference as ref


class ColorMixerReferenceTests(unittest.TestCase):
    def test_checked_fixtures_are_reproducible_without_local_photos(self):
        checked = json.loads(Path(__file__).with_name("fixtures.json").read_text())
        self.assertEqual(checked, generate_fixtures.document())
        self.assertEqual(len(checked["fixtures"]), 4295)
        self.assertEqual({x["group"] for x in checked["fixtures"]}, {"gray", "circle", "p3", "hdr", "boundary", "patch"})

    def test_weights_partition_unity_are_local_and_continuous(self):
        for i in range(8193):
            w = ref.weights(i * math.tau / 8192)
            self.assertLessEqual(abs(sum(w) - 1), 1e-15)
            self.assertTrue(all(0 <= x <= 1 for x in w))
            self.assertLessEqual(sum(x != 0 for x in w), 2)
        for center in (*ref.CENTERS, 0, math.tau):
            left, right = ref.weights(center - 1e-7), ref.weights(center + 1e-7)
            self.assertLess(max(abs(a - b) for a, b in zip(left, right)), 1e-6)

    def test_gray_neutral_orange_and_alpha_are_exact(self):
        doc = generate_fixtures.document()
        neutral, blue = doc["settings"][0]["value"], doc["settings"][1]["value"]
        for version in (1, 2):
            for value in (-.25, 0, .18, 1, 16, 1024):
                rgb = (value,) * 3
                self.assertEqual(ref.apply(rgb, dict(blue, version=version)), rgb)
            orange = tuple(ref.decode_srgb(x) for x in ref.hsv_rgb(30))
            self.assertEqual(ref.apply(orange, dict(blue, version=version)), orange)
            for fixture in doc["fixtures"]:
                rgba = fixture["rgba"]
                pixel = ref.input_pixel(rgba)
                result = ref.reference_pixel(rgba, dict(neutral, version=version))
                self.assertEqual(result[3], pixel[3])
                if pixel[3] > 0:
                    self.assertEqual(result[:3], tuple(x / pixel[3] for x in pixel[:3]))

    def test_scalar_colors_are_continuous_on_both_sides_of_every_band_center(self):
        settings = generate_fixtures.document()["settings"][2]["value"]
        for version in (1, 2):
            for center in (*ref.CENTERS, 0, math.tau):
                results = []
                for offset in (-1e-7, 0, 1e-7):
                    h = center + offset
                    rgb = ref.to_rgb((.65, .12 * math.cos(h), .12 * math.sin(h)))
                    results.append(ref.apply(rgb, dict(settings, version=version)))
                for left, right in zip(results, results[1:]):
                    self.assertLess(max(abs(a - b) for a, b in zip(left, right)), 1e-6)

    def test_signed_and_extended_gamut_stays_unclamped(self):
        settings = {"version": 1, "bands": {"red": {"hue": 5, "saturation": 5, "lightness": 5}}}
        for rgb in ((-1, 2, .1), (16, .2, 0)):
            output = ref.apply(rgb, settings)
            self.assertTrue(all(math.isfinite(x) for x in output))
            self.assertTrue(any(x < 0 or x > 1 for x in output))

    def test_strict_candidate_schema_rejects_undefined_states(self):
        neutral = {"version": 1, "bands": {}}
        for bad in (dict(neutral, version=3), dict(neutral, version=True), dict(neutral, extra=1),
                    {"version": 1, "bands": {"infrared": {}}},
                    {"version": 1, "bands": {"red": {"hue": 1}}},
                    {"version": 1, "bands": {"red": {"hue": 0, "saturation": 0, "lightness": 0}}},
                    {"version": 1, "bands": {"red": {"hue": math.nan, "saturation": 0, "lightness": 0}}},
                    {"version": 1, "bands": {"red": {"hue": 101, "saturation": 0, "lightness": 0}}}):
            with self.assertRaises(ValueError):
                ref.validate(bad)

    def test_numeric_success_cannot_authorize_a_product_feature(self):
        fixtures = {"settings": [{"id": "neutral", "kind": "neutral", "value": {"version": 1, "bands": {}}}],
                    "fixtures": [{"id": "gray", "group": "gray", "rgba": [.25, .25, .25, 1]}]}
        native = {"version": 1, "fixtureCount": 1, "backend": "test", "os": "test",
                  "records": [{"settings": "neutral", "pixels": [.25, .25, .25, 1]}]}
        result = evaluate.summarize(fixtures, native, 1)
        self.assertEqual(result["numericalDecision"], "pass")
        self.assertEqual(result["productionDecision"], "blocked")
        for mutation in ([], native["records"] * 2, [{"settings": "unknown", "pixels": []}]):
            bad = copy.deepcopy(native); bad["records"] = mutation
            with self.assertRaises(ValueError):
                evaluate.summarize(fixtures, bad, 1)

    def test_missing_or_nonfinite_native_pixels_cannot_pass(self):
        fixtures = {"settings": [{"id": "blue-moderate", "kind": "moderate", "value": {"version": 1, "bands": {}}}],
                    "fixtures": [{"id": "hdr", "group": "hdr", "rgba": [1024, 1024, 1024, 1]}]}
        native = {"version": 1, "fixtureCount": 1, "backend": "test", "os": "test",
                  "records": [{"settings": "blue-moderate", "pixels": [1024.001, 1024, 1024, 1]}]}
        self.assertEqual(evaluate.summarize(fixtures, native, 1)["productionDecision"], "no-go")
        native["records"][0]["pixels"][0] = None
        self.assertEqual(evaluate.summarize(fixtures, native, 1)["productionDecision"], "no-go")
        native["records"][0]["pixels"] = []
        with self.assertRaises(ValueError):
            evaluate.summarize(fixtures, native, 1)


if __name__ == "__main__":
    unittest.main()

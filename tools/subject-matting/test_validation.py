import unittest
import numpy as np

from validation import compare, validate_array


class ValidationTests(unittest.TestCase):
    def test_non_finite_reference_and_result_fail_closed(self):
        for bad in (float("nan"), float("inf"), -float("inf")):
            for a, b in (([bad], [0]), ([0], [bad])):
                with self.assertRaisesRegex(ValueError, "non-finite"):
                    compare(a, b)

    def test_shape_and_coverage_are_strict(self):
        for value in ([-0.01], [1.01]):
            with self.assertRaisesRegex(ValueError, "outside"):
                validate_array(value, coverage=True)
        with self.assertRaisesRegex(ValueError, "shape"):
            compare([[0]], [0])
        with self.assertRaisesRegex(ValueError, "shape"):
            compare([], [])

    def test_incorrect_first_prediction_fails_before_good_warm_prediction(self):
        with self.assertRaisesRegex(ValueError, "exceeds"):
            for actual in ([1.0, 1.0], [0.0, 0.0]):
                compare([0.0, 0.0], actual, coverage=True, mean_limit=0.01, p99_limit=0.1)

    def test_finite_metrics_match_expected(self):
        result = compare([0.0, 0.5, 1.0], [0.0, 0.6, 1.0], coverage=True,
                         mean_limit=0.1, p99_limit=0.1)
        self.assertAlmostEqual(result["meanAbsoluteError"], 1 / 30)
        self.assertAlmostEqual(result["maximumAbsoluteError"], 0.1)


if __name__ == "__main__":
    unittest.main()

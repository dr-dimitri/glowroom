import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("evaluation_run", Path(__file__).with_name("run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)


class EvaluationRunnerTests(unittest.TestCase):
    def test_statistics_do_not_invent_small_sample_tail(self):
        self.assertEqual(run.distribution([1, 4, 2, 3, 5])["median_ms"], 3)
        self.assertNotIn("p95_ms", run.distribution(list(range(29))))
        self.assertEqual(run.distribution(list(range(1, 31)))["p95_ms"], 29)
        for values in ([], [float("nan")], [float("inf")], [-1]):
            with self.assertRaises(ValueError):
                run.distribution(values)

    def test_timing_phases_and_inputs_remain_separate(self):
        sample = {"samples": [{"phase": "process-cold", "total_ms": 1000}, {"phase": "warmup", "total_ms": 100}] +
                  [{"phase": "warm", "total_ms": n} for n in range(1, 6)], "input_sha256": "same", "peak_rss_bytes": 200}
        summary = run.timing_summary([sample] * 5)
        self.assertEqual(summary["warm"]["median_ms"], 3)
        self.assertEqual(summary["process_cold"]["n"], 5)
        self.assertNotIn("p95_ms", summary["warm"])
        with self.assertRaises(ValueError):
            run.timing_summary([sample] * 4)
        with self.assertRaises(ValueError):
            run.timing_summary([sample] * 4 + [{**sample, "input_sha256": "different"}])

    def test_real_inputs_need_rights_hash_and_developed_raster(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            image = root / "fixture.png"
            image.write_bytes(b"validation-only")
            entry = {"path": "fixture.png", "sha256": run.digest(image), "source": "self-authored", "license": "CC0",
                     "scene_class": "texture", "permission_to_use": True}
            manifest = root / "real.json"
            manifest.write_text(json.dumps({"files": [entry]}))
            self.assertEqual(run.real_inputs(manifest)[0][0], image.resolve())
            for change in ({"permission_to_use": False}, {"sha256": "wrong"}, {"license": ""}, {"path": "image.CR3"}):
                manifest.write_text(json.dumps({"files": [{**entry, **change}]}))
                with self.assertRaises(ValueError):
                    run.real_inputs(manifest)


if __name__ == "__main__":
    unittest.main()

import copy
import importlib.util
import math
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("personal_tags", Path(__file__).with_name("evaluate.py"))
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


def vector(axis=0, sign=1):
    result = [0.] * e.DIMENSION
    result[axis] = float(sign)
    return result


def dataset():
    generation = "00000000-0000-0000-0000-000000000001"
    rows = []
    for split, count in (("train", 3), ("tune", 2), ("test", 2)):
        for i in range(count):
            aid = split + str(i)
            rows.append({"asset_id": aid, "split": split, "group": aid, "confirmed_revision": 2,
                         "associated": True, "source_revision": "native-1", "embedding_source_revision": "native-1",
                         "embedding_generation": generation, "vector": vector(), "independently_reviewed": True,
                         "confirmed_tags": [{"key": "bäume", "value": "Bäume", "origin": "confirmedAI"}],
                         "draft_tags": ["draft-must-not-train"], "baseline_keys": []})
    return {"schema_version": 1, "descriptor": e.descriptor(), "dataset_kind": "synthetic",
            "catalog_session": "00000000-0000-0000-0000-000000000002", "index_generation": generation,
            "metadata_generation": 4, "rows": rows}


class Centroids(unittest.TestCase):
    def test_confirmed_only_first_spelling_and_origin_preserved(self):
        data = dataset()
        data["rows"][1]["confirmed_tags"][0]["value"] = "BÄUME"
        e.validate(data)
        centroids, training = e.train(data)
        self.assertEqual(list(centroids), ["bäume"])
        self.assertEqual(centroids["bäume"]["value"], "Bäume")
        self.assertEqual(centroids["bäume"]["count"], 3)
        self.assertEqual(training["confirmed_origins"], {"confirmedAI": 3})
        self.assertEqual(training["example_revisions"]["train0"]["confirmed"], 2)

    def test_holdout_vectors_and_labels_never_change_centroids_or_threshold(self):
        original = dataset()
        changed = copy.deepcopy(original)
        for row in changed["rows"]:
            if row["split"] == "test":
                row["vector"] = vector(4)
                row["confirmed_tags"] = []
        self.assertEqual(e.train(original), e.train(changed))
        self.assertEqual(e.evaluate(original)["threshold"], e.evaluate(changed)["threshold"])

    def test_series_and_duplicate_identity_rejected(self):
        for mutation in (lambda d: d["rows"][-1].update(group="train0"),
                         lambda d: d["rows"][-1].update(asset_id="train0")):
            data = dataset()
            mutation(data)
            with self.assertRaises(ValueError):
                e.validate(data)

    def test_model_and_preprocessing_cannot_mix(self):
        for key, value in (("dimension", 512), ("preprocessingVersion", 999), ("modelID", "openclip")):
            data = dataset()
            data["descriptor"][key] = value
            with self.assertRaises(ValueError):
                e.validate(data)

    def test_stale_missing_invalid_and_wrong_generation_are_visible(self):
        changes = [("associated", False), ("confirmed_revision", 0), ("embedding_generation", "old"),
                   ("embedding_source_revision", "stale"), ("vector", []), ("vector", vector(sign=0)),
                   ("vector", [math.nan] * e.DIMENSION)]
        for key, value in changes:
            data = dataset()
            data["rows"][0][key] = value
            centroids, report = e.train(data)
            self.assertFalse(centroids)
            self.assertIn("train0", report["excluded_examples"])
            self.assertEqual(report["rejected_tags"]["bäume"]["reason"], "insufficient_examples")

    def test_nearly_vanishing_means_not_normalized(self):
        data = dataset()
        data["rows"][1]["vector"] = vector(sign=-1)
        extra = copy.deepcopy(data["rows"][1])
        extra.update(asset_id="train3", group="train3")
        data["rows"].append(extra)
        centroids, report = e.train(data)
        self.assertFalse(centroids)
        self.assertEqual(report["rejected_tags"]["bäume"]["reason"], "vanishing_mean")

    def test_language_tags_are_not_semantically_merged(self):
        data = dataset()
        for row in data["rows"][:3]:
            row["confirmed_tags"].append({"key": "trees", "value": "Trees", "origin": "manual"})
        centroids, _ = e.train(data)
        suggestions = e.suggest(vector(), centroids, 0.)
        self.assertEqual([x["key"] for x in suggestions], ["bäume", "trees"])
        self.assertEqual(e.suggest(vector(3), centroids, .1), [])

    def test_metrics_include_counterexamples_rare_tags_and_baseline(self):
        data = dataset()
        data["rows"][-1]["confirmed_tags"] = [{"key": "rare", "value": "Rare", "origin": "manual"}]
        data["rows"][-1]["baseline_keys"] = ["rare"]
        report = e.evaluate(data)
        self.assertEqual(report["test"]["tp"], 1)
        self.assertEqual(report["test"]["fp"], 1)
        self.assertEqual(report["test"]["per_tag"]["rare"]["fn"], 1)
        self.assertEqual(report["image_analysis_baseline"]["tp"], 1)
        self.assertEqual(report["decision"], "NO-GO")

    def test_report_binding_changes_with_manual_confirmation_or_index(self):
        data = dataset()
        before = e.evaluate(data)
        data["metadata_generation"] += 1
        after = e.evaluate(data)
        self.assertNotEqual(before["binding"], after["binding"])
        data["index_generation"] = "00000000-0000-0000-0000-000000000003"
        self.assertFalse(e.train(data)[0])

    def test_no_implicit_truncation_duplicate_keys_or_unconfirmed_origins(self):
        data = dataset()
        data["rows"][0]["confirmed_tags"] *= 2
        with self.assertRaises(ValueError):
            e.validate(data)
        with self.assertRaises(ValueError):
            e.unique_json([("x", 1), ("x", 2)])
        data = dataset()
        data["rows"][0]["confirmed_tags"][0]["origin"] = "pendingAI"
        with self.assertRaises(ValueError):
            e.validate(data)

    def test_abstention_per_tag_and_independent_test_volume(self):
        data = dataset()
        template = copy.deepcopy(data["rows"][-1])
        for index in range(10):
            row = copy.deepcopy(template)
            row.update(asset_id="series" + str(index), group="test1", vector=vector(3))
            data["rows"].append(row)
        report = e.evaluate(data)
        self.assertEqual(report["test"]["photos"], 12)
        self.assertEqual(report["independent_test_groups"], 2)
        self.assertEqual(report["test"]["per_tag"]["bäume"]["abstained_on_positive"], 10)
        self.assertIn("fewer than twelve independent test photos", report["blockers"])

    def test_bool_schema_and_numeric_descriptor_type_drift_rejected(self):
        data = dataset()
        data["schema_version"] = True
        with self.assertRaises(ValueError):
            e.validate(data)
        data = dataset()
        data["descriptor"]["preprocessingVersion"] = True
        with self.assertRaises(ValueError):
            e.validate(data)

    def test_cli_freezes_bytes_and_never_overwrites_existing_outputs(self):
        script = Path(e.__file__)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, plan, report = folder / "input.json", folder / "plan.json", folder / "report.json"
            source.write_text(json.dumps(dataset()), encoding="utf-8")
            def run(*args):
                return subprocess.run([sys.executable, str(script), *map(str, args)], capture_output=True, text=True)
            self.assertEqual(run("freeze", source, plan).returncode, 0)
            self.assertNotEqual(run("freeze", source, plan).returncode, 0)
            self.assertEqual(run("evaluate", source, plan, "--output", report).returncode, 0)
            original = report.read_bytes()
            self.assertEqual(json.loads(original)["decision"], "NO-GO")
            self.assertNotEqual(run("evaluate", source, plan, "--output", report).returncode, 0)
            self.assertEqual(report.read_bytes(), original)
            source.write_text(source.read_text() + "\n")
            other = folder / "must-not-exist.json"
            self.assertNotEqual(run("evaluate", source, plan, "--output", other).returncode, 0)
            self.assertFalse(other.exists())


if __name__ == "__main__":
    unittest.main()

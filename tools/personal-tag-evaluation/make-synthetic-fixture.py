#!/usr/bin/env python3
"""Create a public, content-free fixture; never a photo-quality acceptance set."""
import argparse
import json
from pathlib import Path
import evaluate as e

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
generation = "00000000-0000-0000-0000-000000000001"
data = {"schema_version": 1, "descriptor": e.descriptor(), "dataset_kind": "synthetic",
        "catalog_session": "00000000-0000-0000-0000-000000000002", "index_generation": generation,
        "metadata_generation": 1, "rows": []}
for split, count in (("train", 6), ("tune", 4), ("test", 12)):
    for index in range(count):
        axis = index % 2
        vector = [0.] * e.DIMENSION
        vector[axis] = 1.
        key, value = ("bäume", "Bäume") if axis == 0 else ("trees", "Trees")
        asset = split + str(index)
        data["rows"].append({"asset_id": asset, "group": asset, "split": split,
                             "associated": True, "confirmed_revision": 1, "source_revision": "synthetic-native-1",
                             "embedding_generation": generation, "embedding_source_revision": "synthetic-native-1",
                             "vector": vector, "independently_reviewed": True,
                             "confirmed_tags": [{"value": value, "key": key, "origin": "manual"}],
                             "baseline_keys": [], "draft_tags": ["unconfirmed-do-not-learn"]})
e.validate(data)
with args.output.open("x", encoding="utf-8") as out:
    json.dump(data, out, sort_keys=True, ensure_ascii=False, indent=2, allow_nan=False)
    out.write("\n")

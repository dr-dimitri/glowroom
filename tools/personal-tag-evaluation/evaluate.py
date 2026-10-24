#!/usr/bin/env python3
"""Offline, local-only SigLIP2 centroid qualification. Never opens a catalog."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import platform
import resource
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = "siglip2-confirmed-tag-centroids-v1"
MAX_BYTES = 64 * 1024 * 1024
MAX_ROWS = 4096
MAX_TAGS = 256
DIMENSION = 768
CONFIG = {"minimum_examples": 3, "top_k": 5, "minimum_mean_norm": 1e-6,
          "thresholds": [0.0, 0.2, 0.4, 0.6, 0.8, 0.9, 1.0],
          "minimum_test_photos": 12, "minimum_precision": 0.8,
          "minimum_recall": 0.4, "minimum_f1_gain": 0.05}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def identifier(value):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 512 and "\0" not in value


def unique_json(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path):
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, "64 MiB input limit exceeded")
    return json.loads(data, object_pairs_hook=unique_json,
                      parse_constant=lambda value: require(False, "nonfinite JSON: " + value)), data


def descriptor():
    return read_json(ROOT / "Sources/Glowroom/AI/Resources/SemanticApprovedPackage.json")[0]["descriptor"]


def validate(data):
    require(type(data.get("schema_version")) is int and data["schema_version"] == 1, "unsupported dataset schema")
    require(json.dumps(data.get("descriptor"), sort_keys=True, allow_nan=False) == json.dumps(descriptor(), sort_keys=True),
            "model/preprocessing identity differs from approved SigLIP2")
    require(data["descriptor"]["dimension"] == DIMENSION, "expected 768-dimensional SigLIP2")
    require(data.get("dataset_kind") in ("synthetic", "private_reviewed"), "unknown dataset kind")
    for key in ("catalog_session", "index_generation"):
        require(str(uuid.UUID(data[key])) == data[key], "invalid " + key)
    require(integer(data.get("metadata_generation")), "invalid metadata generation")
    require(isinstance(data.get("rows"), list) and 0 < len(data["rows"]) <= MAX_ROWS, "row budget exceeded/empty")
    ids, groups, keys = set(), {}, {}
    for row in data["rows"]:
        require(identifier(row.get("asset_id")) and row["asset_id"] not in ids, "duplicate/invalid asset")
        ids.add(row["asset_id"])
        require(row.get("split") in ("train", "tune", "test"), "unknown split")
        require(identifier(row.get("group")), "missing series/near-duplicate group")
        require(groups.setdefault(row["group"], row["split"]) == row["split"], "series/near-duplicate split leakage")
        require(integer(row.get("confirmed_revision")), "invalid confirmation revision")
        require(type(row.get("associated")) is bool, "missing current association")
        require(identifier(row.get("source_revision")), "missing current native source revision")
        require(isinstance(row.get("confirmed_tags"), list) and len(row["confirmed_tags"]) <= 20, "invalid confirmed tags")
        seen = set()
        for tag in row["confirmed_tags"]:
            # Export keys with PhotoTextNormalization.tagKey. Do not introduce a
            # second Unicode normalizer or translate/merge the user's taxonomy.
            require(identifier(tag.get("key")) and identifier(tag.get("value"))
                    and len(tag["value"]) <= 60, "invalid canonical tag")
            require(tag["key"] not in seen, "duplicate canonical tag in photo")
            seen.add(tag["key"])
            require(tag.get("origin") in ("manual", "confirmedAI", "imported"), "unconfirmed origin")
            require(keys.setdefault(tag["value"], tag["key"]) == tag["key"], "inconsistent exported normalization")
        baseline = row.get("baseline_keys")
        require(isinstance(baseline, list) and len(baseline) <= 20 and all(identifier(k) for k in baseline)
                and len(set(baseline)) == len(baseline), "missing/invalid independent image-analysis baseline")
        require(type(row.get("independently_reviewed")) is bool, "missing independent label review")
    require({r["split"] for r in data["rows"]} == {"train", "tune", "test"}, "all three splits required")
    require(len({t["key"] for r in data["rows"] for t in r["confirmed_tags"]}) <= MAX_TAGS, "tag budget exceeded")


def vector_problem(row, data):
    if not row["associated"]:
        return "not_currently_associated"
    if row["confirmed_revision"] == 0:
        return "no_confirmation"
    if row.get("embedding_generation") != data["index_generation"]:
        return "wrong_index_generation"
    if row.get("embedding_source_revision") != row["source_revision"]:
        return "stale_or_missing_source"
    vector = row.get("vector")
    if not isinstance(vector, list) or len(vector) != DIMENSION:
        return "missing_or_wrong_dimension"
    if any(type(v) not in (float, int) or not -1.001 <= v <= 1.001 or not math.isfinite(v) for v in vector):
        return "nonfinite_vector"
    norm = math.sqrt(math.fsum(v * v for v in vector))
    if not math.isfinite(norm) or abs(norm - 1) > .001:
        return "not_l2_normalized"
    return None


def train(data):
    accumulators, exclusions, revisions, origins = {}, {}, {}, Counter()
    # Asset order fixes summation and the first preserved spelling. Sequential
    # reduction is intentional: 4096 rows are bounded, and process-pool copies
    # would multiply the private vector memory without useful I/O overlap.
    for row in sorted(data["rows"], key=lambda r: r["asset_id"]):
        if row["split"] != "train":
            continue
        problem = vector_problem(row, data)
        if problem:
            exclusions[row["asset_id"]] = problem
            continue
        if not row["independently_reviewed"]:
            exclusions[row["asset_id"]] = "unreviewed_labels"
            continue
        revisions[row["asset_id"]] = {"confirmed": row["confirmed_revision"], "source": row["source_revision"]}
        for tag in row["confirmed_tags"]:
            key = tag["key"]
            state = accumulators.setdefault(key, {"value": tag["value"], "count": 0, "sum": [0.] * DIMENSION})
            state["count"] += 1
            origins[tag["origin"]] += 1
            for i, value in enumerate(row["vector"]):
                state["sum"][i] += value
    centroids, rejected = {}, {}
    for key, state in sorted(accumulators.items()):
        count = state["count"]
        mean = [x / count for x in state["sum"]]
        norm = math.sqrt(math.fsum(x * x for x in mean))
        if count < CONFIG["minimum_examples"]:
            rejected[key] = {"reason": "insufficient_examples", "count": count}
        elif norm < CONFIG["minimum_mean_norm"]:
            rejected[key] = {"reason": "vanishing_mean", "count": count}
        else:
            centroids[key] = {"value": state["value"], "count": count, "vector": [v / norm for v in mean]}
    return centroids, {"excluded_examples": exclusions, "rejected_tags": rejected,
                       "example_revisions": revisions, "confirmed_origins": dict(origins)}


def suggest(vector, centroids, threshold):
    scored = [(key, math.fsum(a * b for a, b in zip(vector, c["vector"]))) for key, c in centroids.items()]
    return [{"key": key, "value": centroids[key]["value"], "cosine": max(-1., min(1., score))}
            for key, score in sorted(scored, key=lambda pair: (-pair[1], pair[0]))
            if score >= threshold][:CONFIG["top_k"]]


def metrics(cases, baseline=False):
    per_tag = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0, "positive_photos": 0, "abstained_on_positive": 0})
    abstained = 0
    for case in cases:
        truth = set(case["truth"])
        prediction = set(case["baseline"] if baseline else case["predicted"])
        abstained += not prediction
        for key in truth | prediction:
            row = per_tag[key]
            row["tp"] += key in truth & prediction
            row["fp"] += key in prediction - truth
            row["fn"] += key in truth - prediction
            row["positive_photos"] += key in truth
            row["abstained_on_positive"] += key in truth and not prediction
    def finish(row):
        tp, fp, fn = row["tp"], row["fp"], row["fn"]
        return {**row, "precision": tp / (tp + fp) if tp + fp else 0.,
                "recall": tp / (tp + fn) if tp + fn else 0.,
                "f1": 2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else 0.}
    total = {key: sum(r[key] for r in per_tag.values()) for key in ("tp", "fp", "fn")}
    return {**finish(total), "photos": len(cases), "abstained": abstained,
            "per_tag": {k: finish(v) for k, v in sorted(per_tag.items())}}


def cases_for(data, centroids, split, threshold):
    cases = []
    for row in sorted(data["rows"], key=lambda r: r["asset_id"]):
        if row["split"] != split:
            continue
        problem = vector_problem(row, data)
        predictions = [] if problem else suggest(row["vector"], centroids, threshold)
        cases.append({"asset_id": row["asset_id"], "truth": [t["key"] for t in row["confirmed_tags"]],
                      "predicted": [p["key"] for p in predictions], "candidates": predictions,
                      "baseline": row["baseline_keys"], "unscorable": problem,
                      "independently_reviewed": row["independently_reviewed"]})
    return cases


def evaluate(data):
    validate(data)
    centroids, training = train(data)
    trials = [(threshold, metrics(cases_for(data, centroids, "tune", threshold))) for threshold in CONFIG["thresholds"]]
    # Only tuning labels select a threshold. Prefer precision, then abstention
    # on exact ties. Test rows never affect means or threshold selection.
    threshold, _ = max(trials, key=lambda pair: (pair[1]["f1"], pair[1]["precision"], pair[0]))
    cases = cases_for(data, centroids, "test", threshold)
    result, baseline = metrics(cases), metrics(cases, baseline=True)
    blockers = []
    if data["dataset_kind"] != "private_reviewed":
        blockers.append("synthetic fixtures do not establish photo quality")
    if not centroids:
        blockers.append("no eligible centroids")
    independent_groups = len({row["group"] for row in data["rows"] if row["split"] == "test"})
    if independent_groups < CONFIG["minimum_test_photos"]:
        blockers.append("fewer than twelve independent test photos")
    if any(c["unscorable"] or not c["independently_reviewed"] for c in cases_for(data, centroids, "tune", threshold) + cases):
        blockers.append("unreviewed or unscorable tuning/test examples")
    if result["precision"] < CONFIG["minimum_precision"] or result["recall"] < CONFIG["minimum_recall"]:
        blockers.append("precision/recall gate not met")
    if result["f1"] - baseline["f1"] < CONFIG["minimum_f1_gain"]:
        blockers.append("insufficient gain against image-analysis suggestions")
    # Offline label agreement cannot establish the actual user's confirmation
    # benefit. This separate human/native step is deliberately not auto-approved.
    blockers.append("independent confirmation-utility study and native resource measurements required before product release")
    return {"contract": CONTRACT, "decision": "NO-GO" if blockers else "GO", "blockers": blockers,
            "binding": {k: data[k] for k in ("catalog_session", "index_generation", "metadata_generation", "descriptor")},
            "config": CONFIG, "training": training, "eligible_tag_counts": {k: v["count"] for k, v in centroids.items()},
            "tuning": [{"threshold": t, "metrics": m} for t, m in trials], "threshold": threshold,
            "test": result, "independent_test_groups": independent_groups,
            "image_analysis_baseline": baseline, "cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("freeze", "evaluate"):
        p = sub.add_parser(name)
        p.add_argument("dataset", type=Path)
        p.add_argument("plan", type=Path)
        if name == "evaluate":
            p.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data, raw = read_json(args.dataset)
    validate(data)
    # Pin the evaluator itself as well as the dataset and predeclared policy.
    plan = {"contract": CONTRACT, "dataset_sha256": hashlib.sha256(raw).hexdigest(), "config": CONFIG,
            "evaluator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    if args.command == "freeze":
        with args.plan.open("x", encoding="utf-8") as out:
            json.dump(plan, out, sort_keys=True, indent=2, allow_nan=False)
            out.write("\n")
    else:
        require(read_json(args.plan)[0] == plan, "frozen dataset/evaluator/config changed; create a new qualification plan")
        started = time.perf_counter()
        report = evaluate(data)
        report["measurement"] = {"seconds": time.perf_counter() - started,
                                 "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if platform.system() == "Darwin" else 1024),
                                 "system": platform.platform(), "python": platform.python_version(),
                                 "rows": len(data["rows"]), "cache": "offline snapshot, no model inference"}
        report["plan"] = plan
        # Never overwrite a dataset, catalog, original, or previous report.
        with args.output.open("x", encoding="utf-8") as out:
            json.dump(report, out, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False)
            out.write("\n")
        print(report["decision"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit("Qualification rejected: " + str(error)) from error

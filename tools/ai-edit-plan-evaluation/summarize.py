#!/usr/bin/env python3
"""Recheck both native passes against the frozen annotations, never cold alone."""
import argparse
import json
from pathlib import Path
from statistics import median


def summarize(directory, early_no_go=False):
    report = json.loads((directory / "report.json").read_text())
    cases = json.loads((directory / "frozen-cases.json").read_text())
    assert len(cases) == 20 and len({c["id"] for c in cases}) == 20, "Need all frozen cases"
    assert sum(not c["negative"] for c in cases) == 12, "Need twelve positive cases"
    assert sum(c["id"].startswith("absent-") for c in cases) == 4, "Need four absent targets"
    assert sum(c["id"].startswith("multiple-") for c in cases) == 4, "Need four multiple targets"
    rows = {c["id"]: c for c in report["cases"]}
    assert len(rows) == len(report["cases"]) and set(rows).issubset({c["id"] for c in cases}), "Unknown or duplicate cases"
    assert rows, "Native run empty"
    positive = negative = schema_errors = false_positive_plans = 0
    latency = {"cold-app-cache": [], "warm-app-cache": [], "explicit-reference": []}
    peaks = []
    outcomes = []
    for case in cases:
        if case["id"] not in rows:
            continue
        runs = {r["pass"]: r for r in rows[case["id"]]["runs"]}
        assert len(runs) == len(rows[case["id"]]["runs"]), "Duplicate pass names"
        assert "cold-app-cache" in runs and "warm-app-cache" in runs
        if not case["negative"]:
            assert "explicit-reference" in runs
        passes = []
        for name in ("cold-app-cache", "warm-app-cache"):
            run = runs[name]
            if case["negative"]:
                passed = run.get("plan") is False and run.get("error") in {"unsupportedRequest", "noSky", "noSubject"}
                false_positive_plans += run.get("plan") is True
            else:
                passed = (run.get("plan") is True and run.get("target") == case["kind"]
                          and run.get("iou", 0) >= 0.6 and run.get("exposure", 0) * case["direction"] > 0)
            passes.append(passed)
            schema_errors += bool(run.get("schema_error"))
            latency[name].append(run["total_ms"])
            peaks.append(run["cumulative_process_peak_rss_bytes"])
        if "explicit-reference" in runs:
            latency["explicit-reference"].append(sum(float(s["ms"]) for s in runs["explicit-reference"]["stages"]))
        passed = all(passes)
        positive += passed and not case["negative"]
        negative += passed and case["negative"]
        outcomes.append({"id": case["id"], "cold_pass": passes[0], "warm_pass": passes[1], "passed_both": passed})
    measured_positive = sum(not c["negative"] and c["id"] in rows for c in cases)
    measured_negative = sum(c["negative"] and c["id"] in rows for c in cases)
    possible_positive = positive + 12 - measured_positive
    possible_negative = negative + 8 - measured_negative
    incomplete = len(rows) < 20
    assert not incomplete or (early_no_go and (possible_positive < 11 or possible_negative < 8)), "Native run incomplete without a decisive No-Go"
    return {
        "contract": 1, "planned_cases": 20, "completed_cases": len(rows), "positive_passes_both_caches": positive,
        "measured_positive_cases": measured_positive, "measured_negative_cases": measured_negative,
        "negative_refusals_both_caches": negative, "false_positive_negative_plans": false_positive_plans,
        "schema_error_runs": schema_errors,
        "decision": "numerical-pass-unqualified" if not incomplete and positive >= 11 and negative == 8 else "NO-GO",
        "stopped_early": incomplete,
        "maximum_possible_positive_passes": possible_positive,
        "maximum_possible_negative_refusals": possible_negative,
        "unmeasured_cases": [c["id"] for c in cases if c["id"] not in rows],
        "product_release": "Requires full native editor acceptance in addition to this numerical gate",
        "latency_ms": {name: {"count": len(values), "minimum": min(values), "median": median(values), "maximum": max(values)}
                       for name, values in latency.items() if values},
        "process_cumulative_peak_rss_bytes": max(peaks), "cases": outcomes,
        "model_revisions": {key: report[key] for key in ("qwen_revision", "sky_revision", "subject_revision")},
        "measurement_limits": report["limits"],
        "native_cancellation": "Not exercised by this matrix; deterministic contract tests cover cancellation and retained inference admission",
        "concurrent_work": "Developer compilation ran concurrently with bounded CPU jobs. Latency is descriptive under that load, not an isolated performance benchmark.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--early-no-go", action="store_true", help="Accept a partial run only when the full gate is already mathematically impossible")
    args = parser.parse_args()
    result = json.dumps(summarize(args.directory, early_no_go=args.early_no_go), ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as handle:
            handle.write(result)
    else:
        print(result, end="")

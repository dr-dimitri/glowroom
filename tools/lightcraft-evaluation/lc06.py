#!/usr/bin/env python3
"""Frozen LC-06 denoise, native-pixel scaling and controlled timing protocol."""
import hashlib
import html
import json
from pathlib import Path
import platform
import shutil
import subprocess

import run as common
from lc04 import effect_matches, finite

ROOT, SOURCE = common.ROOT, common.SOURCE
CONTROLS = ("luminance", "chroma")


def valid_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def noise_metric(control):
    return "noise_luma_reduction" if control == "luminance" else "noise_chroma_reduction"


def reduction_matches(target, measured, manifest):
    return finite(target) and finite(measured) and target > 0 and measured > 0 and effect_matches(target, measured, manifest)


def matches(record, manifest):
    return record.get("matched") is True and record.get("tuning_matched") is True and reduction_matches(
        record.get("effect_target"), record.get("effect_measured"), manifest)


def numeric_metrics(metrics):
    if not isinstance(metrics, dict) or not metrics or any(not finite(value) for value in metrics.values()):
        raise ValueError("Missing or nonfinite LC-06 metrics")
    return metrics


def measured_reduction(metrics, control):
    prefix = "luma" if control == "luminance" else "chroma"
    before, after = metrics.get(f"input_noise_{prefix}_rmse"), metrics.get(f"noise_{prefix}_rmse")
    value = metrics.get(noise_metric(control))
    if any(not finite(item) for item in (before, after, value)) or before < 0 or after < 0:
        raise ValueError("Incomplete noise-reduction measurement")
    derived = 1 - after / before if before > 1e-12 else 0
    if abs(derived - value) > 1e-10:
        raise ValueError("Reported noise reduction differs from ground-truth RMSE")
    return value


def validate_calibration(tuning, manifest, quality=None):
    expected = {(scene, direction["id"]) for scene in manifest["matching"]["sceneClasses"]
                for direction in manifest["directions"]}
    rows = tuning["records"]
    keys = [(row["sceneClass"], row["directionID"]) for row in rows]
    if len(keys) != len(set(keys)) or set(keys) != expected:
        raise ValueError("Incomplete or duplicate LC-06 frozen calibration")
    indexed = dict(zip(keys, rows))
    for row in rows:
        if (not valid_hash(row.get("inputSHA256")) or not valid_hash(row.get("groundTruthSHA256"))
                or not finite(row.get("parameter")) or not 0 <= row["parameter"] <= 100
                or not finite(row.get("target")) or not finite(row.get("measured"))
                or row.get("matched") is not reduction_matches(row["target"], row["measured"], manifest)):
            raise ValueError("Invalid LC-06 frozen calibration evidence")
    if quality is not None:
        for row in quality["records"]:
            frozen = indexed[(row["scene_class"], row["direction"])]
            if (row.get("parameter") != frozen["parameter"] or row.get("tuning_matched") is not frozen["matched"]
                    or not valid_hash(row.get("input_sha256")) or not valid_hash(row.get("ground_truth_sha256"))
                    or not valid_hash(row.get("output_sha256")) or row["input_sha256"] == frozen["inputSHA256"]
                    or row["ground_truth_sha256"] != frozen["groundTruthSHA256"]):
                raise ValueError("Acceptance refit or missing independent-noise provenance")


def metric_contracts(record, manifest):
    if record.get("finite") is not True:
        raise ValueError("Missing finite-output contract evidence")
    labels = record.get("contract_failures")
    if not isinstance(labels, list) or any(not isinstance(value, str) for value in labels):
        raise ValueError("Missing LC-06 numerical contract evidence")
    metrics = numeric_metrics(record.get("candidate_metrics", record.get("metrics")))
    for key in ("alpha_error", "hidden_rgb_error"):
        if not finite(metrics.get(key)) or metrics[key] < 0:
            raise ValueError("Incomplete LC-06 alpha/hidden-RGB evidence")
    failures = []
    if metrics["alpha_error"] > manifest["contracts"]["alphaTolerance"]:
        failures.append("alpha_error")
    if metrics["hidden_rgb_error"] > 0:
        failures.append("hidden_rgb_error")
    return failures


def support(metrics, names):
    return all(finite(metrics.get(name)) and metrics[name] > 0 for name in names)


def contracts(quality, manifest):
    expected = {(scene, control, value) for scene in manifest["matching"]["sceneClasses"]
                for control in CONTROLS for value in manifest["contracts"]["neutralValues"]}
    rows = quality.get("zero_diagnostics", [])
    keys = [(r["scene_class"], r["control"], r["value"]) for r in rows]
    if len(set(keys)) != len(keys) or any(key not in expected for key in keys):
        raise ValueError("Duplicate or unknown LC-06 zero-transition diagnostic")
    result = {}
    for control in CONTROLS:
        required = {key for key in expected if key[1] == control}
        present = {key for key in keys if key[1] == control}
        missing = [] if required == present else ["Complete zero/near-zero diagnostic and identity matrix"]
        failures = []
        for row in rows:
            if row["control"] != control:
                continue
            problems = metric_contracts(row, manifest)
            if row["value"] == 0:
                before, after = row.get("input_sha256"), row.get("output_sha256")
                if not valid_hash(before) or not valid_hash(after) or row.get("identity") is not (before == after):
                    raise ValueError("Invalid exact-zero identity provenance")
                if before != after:
                    problems.append("zero_identity")
            failures.extend(f"{row['scene_class']}/{row['value']}: {p}" for p in problems)
        for row in quality["records"]:
            if row["control"] == control:
                failures.extend(f"{row['scene_class']}/{row['direction']}: {p}" for p in metric_contracts(row, manifest))
        result[control] = {"status": "fail" if failures else ("blocked" if missing else "pass"),
                           "failures": failures, "missing_evidence": missing,
                           "zero_diagnostics": len(present), "expected_zero_diagnostics": len(required)}
    return result


def primary_comparison(rows, expected_count, manifest):
    spec = manifest["primary"]
    result = {"status": "blocked", "reference": "clean ground truth", "metrics": {}}
    if len(rows) != expected_count or not rows or any(not matches(row, manifest) for row in rows):
        return result
    required = ("noise_sample_count", "noise_visible_weight", "detail_sample_count", "detail_visible_weight",
                "edge_sample_count", "edge_visible_weight")
    if any(not support(metrics, required) or any(not finite(metrics.get(key)) or metrics[key] < 0 for key in spec["metrics"])
           for row in rows for metrics in (row["baseline_metrics"], row["candidate_metrics"])):
        return result
    passed, informative = True, 0
    for metric, limits in spec["metrics"].items():
        baseline = sum(row["baseline_metrics"][metric] for row in rows) / len(rows)
        candidate = sum(row["candidate_metrics"][metric] for row in rows) / len(rows)
        signal = baseline > limits["baselineFloor"]
        improvement = (baseline - candidate) / baseline if signal else None
        regressions = []
        for row in rows:
            before, after = row["baseline_metrics"][metric], row["candidate_metrics"][metric]
            if after - before > max(limits["maximumPerCaseAbsoluteRegression"], limits["maximumPerCaseRelativeRegression"] * before):
                regressions.append(f"{row['scene_class']}/{row['direction']}: +{after - before:.9g}")
        okay = (improvement >= spec["minimumRelativeImprovement"] if signal else candidate <= limits["baselineFloor"]) and not regressions
        passed = passed and okay
        informative += int(signal)
        result["metrics"][metric] = {"status": "pass" if okay else "fail", "baseline_mean": baseline,
                                     "candidate_mean": candidate, "informative": signal,
                                     "relative_improvement": improvement, "regressions": regressions}
    result.update(status="fail" if not passed else ("pass" if informative else "blocked"), informative_targets=informative,
                  note="Equal scene/amount weights on independent noise seeds; no pixel-independence or statistical-significance claim")
    return result


def critical_evidence(record, manifest):
    before, after = record["baseline_metrics"], record["candidate_metrics"]
    pairs = [("luma_drift_mean", "lumaDriftMeanIncrease"), ("gamut_fraction", "gamutFractionIncrease"),
             ("clipping_fraction", "clippingFractionIncrease")]
    failures, missing = [], []
    # Flat fields intentionally contain no true edge. They cannot establish a
    # fringing result, while their drift/gamut guards remain meaningful.
    if record["scene_class"] not in ("flat-dark", "flat-bright"):
        if all(support(metrics, ("edge_sample_count", "edge_visible_weight")) for metrics in (before, after)):
            pairs.append(("chroma_fringing_rmse", "chromaFringingIncrease"))
        else:
            missing.append("ground-truth-defined edge support")
    for metric, threshold in pairs:
        if any(not finite(metrics.get(metric)) or metrics[metric] < 0 for metrics in (before, after)):
            missing.append(metric)
        elif after[metric] - before[metric] > manifest["criticalLimits"][threshold]:
            failures.append(metric)
    return failures, missing


def decide(quality, manifest, performance=()):
    directions = {d["id"]: d for d in manifest["directions"]}
    expected = {(scene, direction) for scene in manifest["matching"]["sceneClasses"] for direction in directions}
    records = quality["records"]
    keys = [(r["scene_class"], r["direction"]) for r in records]
    if len(keys) != len(set(keys)) or any(key not in expected for key in keys):
        raise ValueError("Duplicate or unknown LC-06 quality record")
    for row in records:
        if row["control"] != directions[row["direction"]]["control"]:
            raise ValueError("LC-06 direction/control mismatch")
        for effect, metrics in (("effect_target", "baseline_metrics"), ("effect_measured", "candidate_metrics")):
            values = numeric_metrics(row[metrics])
            reduction = measured_reduction(values, row["control"])
            if not finite(row.get(effect)) or abs(row[effect] - reduction) > 1e-10:
                raise ValueError("LC-06 matching strength differs from measured noise reduction")
    if any(p.get("control") not in CONTROLS for p in performance):
        raise ValueError("Unknown LC-06 performance control")
    contract_evidence = contracts(quality, manifest)
    indexed = dict(zip(keys, records))
    decisions = {}
    for control in CONTROLS:
        failures = list(contract_evidence[control]["failures"])
        missing = list(manifest["requiredMissingUntilMeasured"]) + contract_evidence[control]["missing_evidence"]
        expected_control = {key for key in expected if directions[key[1]]["control"] == control}
        rows = [row for row in records if row["control"] == control]
        if not expected_control.issubset(indexed):
            missing.append("Complete independent-noise acceptance matrix")
        unmatched = [f"{r['scene_class']}/{r['direction']}" for r in rows if not matches(r, manifest)]
        if unmatched:
            missing.append("Unmatched or unsupported noise-reduction targets: " + ", ".join(unmatched))
        for row in rows:
            if matches(row, manifest):
                derived, absent = critical_evidence(row, manifest)
                failures.extend(f"{row['scene_class']}/{row['direction']}: {item}" for item in derived)
                if absent:
                    missing.append(f"{row['scene_class']}/{row['direction']}: missing critical evidence: " + ", ".join(absent))
        wanted = [(scene, d["id"]) for scene in manifest["primary"]["sceneClasses"]
                  for d in manifest["directions"] if d["control"] == control and d["primary"]]
        primary = primary_comparison([indexed[key] for key in wanted if key in indexed], len(wanted), manifest)
        if primary["status"] == "fail":
            failures.append("Complete matched ground-truth detail/edge target failed")
        elif primary["status"] == "blocked":
            missing.append("Complete informative matched primary matrix with noise/detail/edge support")
        timings = [item for item in performance if item["control"] == control]
        wanted_sizes = {tuple(size) for size in manifest["performanceBudgets"]["sizes"]}
        measured_sizes = {(item["width"], item["height"]) for item in timings}
        if len(measured_sizes) != len(timings) or not measured_sizes.issubset(wanted_sizes):
            raise ValueError("Duplicate or unknown LC-06 performance size")
        for item in timings:
            failures.extend(f"{item['width']}x{item['height']}: {failure}" for failure in item["failures"])
        if measured_sizes != wanted_sizes:
            missing.append("Complete controlled cold/warm performance and peak RSS matrix")
        if any(item.get("attributable") is not True for item in timings):
            missing.append("Matched per-size timing noise-reduction targets")
        decisions[control] = {"decision": "no-go" if failures else "blocked", "primary": primary,
                              "contracts": contract_evidence[control], "critical_failures": failures,
                              "missing_evidence": missing, "quality_records": len(rows),
                              "matched_records": len(rows) - len(unmatched),
                              "scope": "Isolated CPU denoise reference at native scale; production unchanged"}
    return decisions


def scaling_decision(scale, manifest):
    spec = manifest["scaling"]
    if scale.get("full_size") != spec["nativeSize"]:
        raise ValueError("Scaling native-size metadata mismatch")
    directions = {d["id"]: d for d in manifest["directions"]}
    expected = {(d["control"], d["id"], width, height, variant) for d in directions.values()
                for width, height in spec["previewSizes"] for variant in spec["variants"]}
    rows = scale.get("records", [])
    keys = [(r["control"], r["direction"], r["width"], r["height"], r["variant"]) for r in rows]
    if len(keys) != len(set(keys)) or any(key not in expected for key in keys):
        raise ValueError("Duplicate or unknown LC-06 scaling record")
    indexed = dict(zip(keys, rows))
    missing = list(manifest["requiredMissingUntilMeasured"])
    failures, primary = [], {}
    if set(keys) != expected:
        missing.append("Complete independent native/unscaled/PicEdit scaling matrix")
    hash_keys = ("input_sha256", "ground_truth_sha256", "full_input_sha256", "full_ground_truth_sha256", "full_output_sha256", "output_sha256")
    for row in rows:
        if row.get("finite") is not True:
            raise ValueError("Missing finite-output scaling evidence")
        if any(not valid_hash(row.get(key)) for key in hash_keys):
            raise ValueError("Invalid LC-06 scaling provenance")
        if (row.get("sampling") != spec["inputSampling"] or row.get("native_long") != max(spec["nativeSize"])
                or row.get("pixels_per_long_edge") != max(row["width"], row["height"])):
            raise ValueError("Scaling geometry/sampling metadata mismatch")
        if not finite(row.get("parameter")) or not 0 <= row["parameter"] <= 100:
            raise ValueError("Invalid scaling amount")
        for key in ("metrics", "quality_metrics", "full_quality_metrics", "identity_metrics"):
            numeric_metrics(row.get(key))
        # Independent output contracts remain decisive even when the unscaled
        # comparison or the diagnostic PicEdit record is absent.
        if row["variant"] == "nativePixels":
            problems = set()
            for key in ("quality_metrics", "full_quality_metrics"):
                problems.update(metric_contracts({"finite": True, "contract_failures": [], "metrics": row[key]}, manifest))
            label = f"{row['direction']}/{row['width']}x{row['height']}"
            failures.extend(f"{label}: {problem}" for problem in sorted(problems))
    for key in ("full_input_sha256", "full_ground_truth_sha256"):
        if len({row[key] for row in rows}) > 1:
            raise ValueError("Scaling matrix changed the full source or clean truth")
    for width, height in spec["previewSizes"]:
        group = [row for row in rows if (row["width"], row["height"]) == (width, height)]
        for key in ("input_sha256", "ground_truth_sha256"):
            if len({row[key] for row in group}) > 1:
                raise ValueError("Scaling matrix changed preview inputs between directions")
    for direction in directions:
        for diagnostic in (False, True):
            group = [row for row in rows if row["direction"] == direction and (row["variant"] == "picedit") == diagnostic]
            for key in ("full_output_sha256", "parameter"):
                if len({row[key] for row in group}) > 1:
                    raise ValueError("Scaling matrix changed the formula or full output between sizes")
    for control in CONTROLS:
        comparisons = []
        for direction in (d for d in directions.values() if d["control"] == control):
            for width, height in spec["previewSizes"]:
                triplet = [indexed.get((control, direction["id"], width, height, variant)) for variant in spec["variants"]]
                if any(row is None for row in triplet):
                    continue
                by_variant = {row["variant"]: row for row in triplet}
                candidate, baseline = by_variant["nativePixels"], by_variant["unscaled"]
                for key in hash_keys[:4]:
                    if len({row[key] for row in triplet}) != 1:
                        raise ValueError("Scaling adapters received different source/ground-truth rasters")
                if (candidate["parameter"] != baseline["parameter"] or
                        candidate["full_output_sha256"] != baseline["full_output_sha256"] or
                        candidate["full_quality_metrics"] != baseline["full_quality_metrics"] or
                        candidate["identity_metrics"] != baseline["identity_metrics"]):
                    raise ValueError("Scaling ablation changed formula amount or native reference")
                label = f"{direction['id']}/{width}x{height}"
                quality, full = candidate["quality_metrics"], candidate["full_quality_metrics"]
                required = ("noise_sample_count", "noise_visible_weight", "detail_sample_count", "detail_visible_weight",
                            "edge_sample_count", "edge_visible_weight")
                supported = all(support(values, required) for values in (quality, full))
                target, measured = measured_reduction(full, control), measured_reduction(quality, control)
                signal = finite(target) and finite(measured) and target >= spec["minimumNoiseReduction"]
                if not supported or not signal:
                    missing.append(f"{label}: informative full/preview noise/detail/edge support")
                elif measured <= 0 or abs(target - measured) > max(spec["maximumNoiseReductionAbsoluteError"], spec["maximumNoiseReductionRelativeError"] * abs(target)):
                    failures.append(f"{label}: preview_noise_reduction")
                distance = spec["distanceMetrics"][control]
                before, after = baseline["metrics"].get(distance), candidate["metrics"].get(distance)
                if not finite(before) or not finite(after) or before < 0 or after < 0:
                    raise ValueError("Missing scaling distance")
                if supported and signal:
                    if after > spec["maximumDistance"]:
                        failures.append(f"{label}: {distance}")
                    for metric in spec["qualityMetrics"]:
                        a, b = full.get(metric), quality.get(metric)
                        if not finite(a) or not finite(b) or a < 0 or b < 0:
                            missing.append(f"{label}: {metric}")
                        elif b - a > max(spec["maximumQualityAbsoluteRegression"], spec["maximumQualityRelativeRegression"] * a):
                            failures.append(f"{label}: {metric}")
                    comparisons.append((before, after))
        expected_count = sum(d["control"] == control for d in directions.values()) * len(spec["previewSizes"])
        result = {"status": "blocked", "complete_supported_cases": len(comparisons), "expected_cases": expected_count,
                  "metric": spec["distanceMetrics"][control]}
        if len(comparisons) == expected_count:
            before = sum(pair[0] for pair in comparisons) / expected_count
            after = sum(pair[1] for pair in comparisons) / expected_count
            informative = before > spec["distanceFloor"]
            gain = (before - after) / before if informative else None
            status = ("pass" if gain >= spec["minimumRelativeImprovement"] else "fail") if informative else "blocked"
            result.update(status=status, unscaled_mean=before, native_pixels_mean=after, informative=informative, relative_improvement=gain)
            if status == "fail":
                failures.append(f"{control}: complete informative scaling distance target failed")
        if result["status"] == "blocked":
            missing.append(f"{control}: complete informative scaling distance target")
        primary[control] = result
    return {"decision": "no-go" if failures else "blocked", "primary": primary, "critical_failures": failures,
            "missing_evidence": missing, "records": len(rows),
            "scope": "Same frozen formula amount with nativePixels versus unscaled; area-averaged input and truth. PicEdit diagnostic only."}


def validate_scaling_calibration(scale, tuning, manifest):
    frozen = {(row["sceneClass"], row["directionID"]): row["parameter"] for row in tuning["records"]}
    directions = {row["id"]: row for row in manifest["directions"]}
    for row in scale["records"]:
        amount = (directions[row["direction"]]["value"] if row["variant"] == "picedit"
                  else frozen[(manifest["scaling"]["sceneClass"], row["direction"])])
        if row["parameter"] != amount:
            raise ValueError("Scaling changed the frozen quality amount")


def performance_comparison(control, width, height, baseline_runs, candidate_runs, manifest):
    if control not in CONTROLS or len(baseline_runs) != len(candidate_runs):
        raise ValueError("Invalid control or different process counts")
    for adapter, runs in (("picedit", baseline_runs), ("lightcraft", candidate_runs)):
        for run in runs:
            if (run.get("width"), run.get("height"), run.get("control"), run.get("adapter")) != (width, height, control, f"{adapter}-{control}"):
                raise ValueError("Timing geometry/control/adapter metadata mismatch")
            if not finite(run.get("peak_rss_bytes")) or run["peak_rss_bytes"] <= 0:
                raise ValueError("Invalid process peak RSS")
    for runs in (baseline_runs, candidate_runs):
        if len(runs) != manifest["performanceBudgets"]["minimumColdProcesses"]:
            raise ValueError("Incomplete LC-06 process matrix")
        for run in runs:
            schedule = [sample["phase"] for sample in run["samples"]]
            if schedule != ["process-cold", "warmup"] + ["warm"] * manifest["performanceBudgets"]["minimumWarmSamplesPerProcess"]:
                raise ValueError("Unexpected LC-06 timing schedule")
            if not valid_hash(run.get("ground_truth_sha256")):
                raise ValueError("Missing timing ground truth")
    if len({run["ground_truth_sha256"] for run in baseline_runs + candidate_runs}) != 1:
        raise ValueError("Timing adapters received different ground truth")
    baseline, candidate = common.timing_summary(baseline_runs), common.timing_summary(candidate_runs)
    if baseline["input_sha256"] != candidate["input_sha256"]:
        raise ValueError("Timing adapters received different inputs")
    phases = {name: [] for name in ("process-cold", "warmup", "warm")}
    pairs = []
    for before_run, after_run in zip(baseline_runs, candidate_runs):
        if len(before_run["samples"]) != len(after_run["samples"]):
            raise ValueError("Timing schedules differ")
        for before, after in zip(before_run["samples"], after_run["samples"]):
            phase = before["phase"]
            if phase != after["phase"] or phase not in phases:
                raise ValueError("Timing phase schedules differ")
            match = reduction_matches(before.get("effect_strength"), after.get("effect_strength"), manifest)
            phases[phase].append(match)
            pairs.append({"phase": phase, "picedit": before.get("effect_strength"), "lightcraft": after.get("effect_strength"), "matched": match})
    all_matched = all(values and all(values) for values in phases.values())
    numerators = {"cold_latency_ratio": candidate["process_cold"]["median_ms"], "warm_latency_ratio": candidate["warm"]["median_ms"], "peak_rss_ratio": candidate["peak_rss_bytes"]}
    denominators = {"cold_latency_ratio": baseline["process_cold"]["median_ms"], "warm_latency_ratio": baseline["warm"]["median_ms"], "peak_rss_ratio": baseline["peak_rss_bytes"]}
    if any(not finite(v) or v <= 0 for v in denominators.values()) or any(not finite(v) or v < 0 for v in numerators.values()):
        raise ValueError("Invalid timing or memory measurement")
    ratios = {key: value / denominators[key] for key, value in numerators.items()}
    budgets = manifest["performanceBudgets"]
    limits = {"cold_latency_ratio": budgets["maximumColdLatencyRatio"], "warm_latency_ratio": budgets["maximumWarmLatencyRatio"], "peak_rss_ratio": budgets["maximumPeakRSSRatio"]}
    attribution = {"cold_latency_ratio": bool(phases["process-cold"]) and all(phases["process-cold"]),
                   "warm_latency_ratio": bool(phases["warm"]) and all(phases["warm"]), "peak_rss_ratio": all_matched}
    exceeded = {key: f"{key} {ratios[key]:.6g} exceeds {limit}" for key, limit in limits.items() if ratios[key] > limit}
    return {"control": control, "width": width, "height": height, "picedit": baseline, "lightcraft": candidate,
            "ratios": ratios, "attributable": all_matched, "phase_attribution": attribution, "effect_strength_pairs": pairs,
            "budget_exceedances": list(exceeded.values()), "failures": [value for key, value in exceeded.items() if attribution[key]],
            "note": "Isolated CPU denoise reference including conversion/readback; no accelerated-path claim. Warm samples share process caches."}


def views(output, records):
    style = "body{font:15px system-ui;margin:2rem;background:#eee;color:#222}section{margin:2rem 0}figure{display:inline-block;margin:8px}img{width:384px;image-rendering:pixelated}figcaption{max-width:384px}"
    labeled = [f"<!doctype html><meta charset='utf-8'><title>LC-06 comparisons</title><style>{style}</style><h1>LC-06 comparisons</h1><p>Luminance denoise, chroma denoise and native-pixel scaling have separate decisions. Quality uses independent-noise clean ground truth at matched flat-region noise reduction.</p>"]
    blind = [f"<!doctype html><meta charset='utf-8'><title>LC-06 blind pairs</title><style>{style}</style><h1>LC-06 blind pairs</h1><p>Record preference and defects before opening blind-key.json. Generated pairs are not completed visual approval.</p>"]
    key = []
    (output / "blind").mkdir()
    for number, record in enumerate(records, 1):
        directory = Path("quality") / record["directory"]
        if directory.is_absolute() or ".." in directory.parts:
            raise ValueError("Invalid quality image directory")
        title = html.escape(f"{record['fixture']} · {record['direction']} · matched={record['matched']}")
        labeled.append(f"<section><h2>{title}</h2>")
        for filename, label in (("input.png", "Noisy input"), ("ground-truth.png", "Clean ground truth"), ("picedit.png", "PicEdit"), ("lightcraft.png", "Matched candidate"),
                                ("same-values.png", "Candidate same values"), ("difference.png", "Difference ×8"),
                                ("dark.png", "Dark composite"), ("light.png", "Light composite")):
            path = directory / filename
            if not (output / path).is_file():
                raise ValueError(f"Missing image artifact: {path}")
            labeled.append(f"<figure><img src='{html.escape(path.as_posix(), quote=True)}'><figcaption>{label}</figcaption></figure>")
        labeled.append("</section>")
        pair = [("picedit.png", "picedit"), ("lightcraft.png", "lightcraft")]
        if hashlib.sha256(f"lc06-blind-v1:{record['fixture']}:{record['direction']}:lightcraft".encode()).digest()[0] % 2:
            pair.reverse()
        blind.append(f"<section><h2>Pair {number:03d}</h2>")
        entry = {"pair": number, "fixture": record["fixture"], "direction": record["direction"], "variant": "lightcraft", "matched": record["matched"]}
        for label, (filename, adapter) in zip(("A", "B"), pair):
            target = Path("blind") / f"{number:03d}-{label}.png"
            shutil.copyfile(output / directory / filename, output / target)
            blind.append(f"<figure><img src='{target.as_posix()}'><figcaption>{label}</figcaption></figure>")
            entry[label] = adapter
        key.append(entry)
        blind.append("</section>")
    (output / "labeled.html").write_text("\n".join(labeled))
    (output / "blind.html").write_text("\n".join(blind))
    common.write_json(output / "blind-key.json", key)


def execute(args):
    if args.real_manifest:
        raise ValueError("LC-06 has no registered real-photo ROIs; --real-manifest remains an LC-01 diagnostic option")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    protocol_source = SOURCE / "lc06-manifest.json"
    manifest = json.loads(protocol_source.read_text())
    frozen = output / protocol_source.name
    frozen.write_bytes(protocol_source.read_bytes())
    sources = list((ROOT / "Sources").rglob("*.swift"))
    sources += [ROOT / "Package.swift", ROOT / "Package.resolved", SOURCE / "run.py", SOURCE / "lc04.py", Path(__file__),
                ROOT / "scripts/evaluate-lightcraft.sh", ROOT / "scripts/build-developer-tool.sh",
                SOURCE / "THIRD-PARTY-NOTICES.txt", SOURCE / "candidate-registry.json"]
    sources += [p for folder in ("lc06-reference-oracle", "licenses") for p in (SOURCE / folder).rglob("*")
                if p.is_file() and "__pycache__" not in p.parts]
    hashes = {str(p.relative_to(ROOT)): common.digest(p) for p in sorted(set(sources)) if p.is_file()}
    hardware = common.command(["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini"])
    hardware = "\n".join(line for line in hardware.splitlines() if not any(k in line for k in ("Serial Number", "Hardware UUID", "Provisioning UDID")))
    budgets = manifest["performanceBudgets"]
    metadata = {"schema_version": 1, "candidate": "LC-06", "base_commit": common.command(["git", "rev-parse", "HEAD"]),
                "source_sha256": hashes, "binary_sha256": common.digest(args.binary), "manifest_sha256": common.digest(frozen),
                "toolchain": common.command(["xcrun", "swift", "--version"]), "os": common.command(["sw_vers"]),
                "hardware": hardware, "architecture": platform.machine(), "timing_concurrency": 1,
                "configuration": "release, existing editing harness", "backend": "PicEdit: Core Image automatic; isolated denoise reference: bounded CPU",
                "timing_order": "Per control and size, paired separate processes; alternate first adapter each repetition. Serial measurements avoid CPU/GPU/memory contention.",
                "sizes": budgets["sizes"], "repetitions": budgets["minimumColdProcesses"],
                "warm_samples_per_process": budgets["minimumWarmSamplesPerProcess"], "warmups_per_process": 1,
                "timing_scene": manifest["performanceSceneClass"], "real_inputs": "none"}
    common.write_json(output / "environment.json", metadata)
    invocations, calibration_hash = [], None
    calibration = output / "tuning/calibration.json"

    def unchanged():
        if common.digest(protocol_source) != metadata["manifest_sha256"] or common.digest(frozen) != metadata["manifest_sha256"]:
            raise ValueError("LC-06 protocol changed during evaluation")
        if common.digest(args.binary) != metadata["binary_sha256"] or any(common.digest(ROOT / p) != h for p, h in hashes.items()):
            raise ValueError("LC-06 binary or sources changed during evaluation")
        if calibration_hash is not None and common.digest(calibration) != calibration_hash:
            raise ValueError("Calibration changed after tuning was frozen")

    def invoke(mode, name, width=None, height=None, adapter=None):
        unchanged()
        cmd = [str(args.binary.resolve()), "--scenario", "evaluation", "--evaluation-mode", "denoise-" + mode,
               "--manifest", str(frozen), "--output", str(output / name), "--width", str(width or manifest["qualityWidth"]),
               "--height", str(height or manifest["qualityHeight"]), "--iterations", str(budgets["minimumWarmSamplesPerProcess"])]
        if mode != "tune":
            cmd += ["--calibration", str(calibration)]
        if adapter:
            cmd += ["--adapter", adapter]
        invocations.append(cmd)
        common.write_json(output / "commands.json", invocations)
        print(f"LC-06: {name}", flush=True)
        with (output / f"{name}.log").open("w") as log:
            subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        unchanged()

    invoke("tune", "tuning")
    tuning = json.loads(calibration.read_text())
    if tuning["manifestSHA256"] != metadata["manifest_sha256"]:
        raise ValueError("Tuning used a different protocol")
    validate_calibration(tuning, manifest)
    calibration_hash = common.digest(calibration)
    metadata["calibration_sha256"] = calibration_hash
    common.write_json(output / "environment.json", metadata)
    invoke("quality", "quality")
    quality = json.loads((output / "quality/quality.json").read_text())
    if quality["manifest_sha256"] != metadata["manifest_sha256"] or quality["calibration_sha256"] != calibration_hash:
        raise ValueError("Acceptance used a different frozen protocol or calibration")
    validate_calibration(tuning, manifest, quality)
    # Validate contracts/matrix before expensive timing; a no-go is still a
    # complete experiment, whereas malformed evidence must abort the run.
    decide(quality, manifest)
    views(output, quality["records"])
    performance = []
    for control in CONTROLS:
        for width, height in budgets["sizes"]:
            adapters = {"picedit": [], "lightcraft": []}
            for number in range(1, budgets["minimumColdProcesses"] + 1):
                # Development can be parallel; competing measurements cannot.
                order = ("picedit", "lightcraft") if number % 2 else ("lightcraft", "picedit")
                for adapter in order:
                    name = f"timing-{control}-{width}-{adapter}-{number}"
                    invoke("timing", name, width, height, f"{adapter}-{control}")
                    adapters[adapter].append(json.loads((output / name / "timing.json").read_text()))
            performance.append(performance_comparison(control, width, height, adapters["picedit"], adapters["lightcraft"], manifest))
    invoke("scale", "scale", *budgets["sizes"][-1])
    unchanged()
    decisions = decide(quality, manifest, performance)
    scale = json.loads((output / "scale/scale.json").read_text())
    validate_scaling_calibration(scale, tuning, manifest)
    decisions["scaling"] = scaling_decision(scale, manifest)
    summary = {"schema_version": 1, "candidate": "LC-06", "decisions": decisions, "timings": performance,
               "manifest_sha256": metadata["manifest_sha256"], "calibration_sha256": calibration_hash,
               "quality": "quality/quality.json", "scale": "scale/scale.json", "production_changed": False}
    common.write_json(output / "summary.json", summary)
    print(f"LC-06 complete ({', '.join(c + ': ' + d['decision'] for c, d in decisions.items())}): {output / 'summary.json'}", flush=True)

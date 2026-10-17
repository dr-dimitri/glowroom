#!/usr/bin/env python3
"""Frozen LC-04 detail protocol; independent clarity and texture decisions."""
import hashlib
import html
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess

import run as common

ROOT, SOURCE = common.ROOT, common.SOURCE
CANDIDATES = {"clarity": "clarityGuidedLog", "texture": "textureGaussianLogTamed"}
VARIANTS = {"clarity": ("clarityGuidedLog", "clarityGaussianLog"),
            "texture": ("textureGaussianExistingDomain", "textureGaussianLog", "textureGaussianLogTamed")}


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def effect_matches(target, measured, manifest):
    limits = manifest["matching"]
    return (finite(target) and finite(measured) and target * measured > 0
            and abs(target) >= limits["minimumAbsoluteTarget"]
            and abs(target - measured) <= max(limits["maximumAbsoluteDeltaError"],
                                              abs(target) * limits["maximumRelativeDeltaError"]))


def matched(record, manifest):
    # Recompute from the actual acceptance effect, not just a native boolean or
    # the tuning fit. Opposite-sign and effectively neutral results never gate.
    return record.get("matched") is True and effect_matches(record.get("effect_target"), record.get("effect_measured"), manifest)


def primary_comparison(rows, spec, manifest, comparison_rows=None):
    metric = spec["metric"]
    result = {"status": "blocked", "metric": metric}
    valid = bool(rows) and all(matched(r, manifest) for r in rows)
    baseline_metrics = [r["baseline_metrics"] for r in rows]
    if comparison_rows is not None:
        valid = valid and len(comparison_rows) == len(rows) and all(matched(r, manifest) for r in comparison_rows)
        baseline_metrics = [r["candidate_metrics"] for r in comparison_rows]
    candidate_metrics = [r["candidate_metrics"] for r in rows]
    for metrics in baseline_metrics + candidate_metrics:
        valid = valid and finite(metrics.get(metric)) and metrics[metric] >= 0
        valid = valid and all(finite(metrics.get(key)) and metrics[key] > 0
                              for key in spec["sampleCountMetrics"])
    if not valid:
        return result
    baseline = sum(r[metric] for r in baseline_metrics) / len(rows)
    candidate = sum(r[metric] for r in candidate_metrics) / len(rows)
    improvement = (baseline - candidate) / baseline if baseline > 0 else 0
    regressions = [f"{r['scene_class']}/{r['direction']}: +{after[metric] - before[metric]:.9g}"
                   for r, before, after in zip(rows, baseline_metrics, candidate_metrics)
                   if after[metric] - before[metric] > spec["maximumPerCaseRegression"]]
    passed = improvement >= spec["minimumRelativeImprovement"] and not regressions
    result.update(status="pass" if passed else "fail", baseline_mean=baseline,
                  candidate_mean=candidate, relative_improvement=improvement, regressions=regressions)
    return result


def neutral_contracts(quality, manifest):
    """Zero has an exact identity contract, independent of effect normalization."""
    rows = quality.get("zero_diagnostics", [])
    expected = {(scene, control, variant, value) for scene in manifest["matching"]["sceneClasses"]
                for control, variants in VARIANTS.items() for variant in variants for value in (-1, 0, 1)}
    keys = [(r["scene_class"], r["control"], r["variant"], r["value"]) for r in rows]
    if len(keys) != len(set(keys)) or any(key not in expected for key in keys):
        raise ValueError("Duplicate or unknown LC-04 zero-transition diagnostic")
    result = {}
    for control, candidate in CANDIDATES.items():
        control_keys = {key for key in keys if key[1] == control}
        required = {key for key in expected if key[1] == control}
        failures, diagnostic_failures = [], []
        for row in rows:
            if row["control"] != control or row["value"] != 0:
                continue
            before, after = row.get("input_sha256"), row.get("output_sha256")
            valid_hashes = all(isinstance(value, str) and len(value) == 64 and
                               all(c in "0123456789abcdef" for c in value) for value in (before, after))
            if not valid_hashes:
                raise ValueError("Invalid zero-transition raster provenance")
            if row.get("identity") is not (before == after):
                raise ValueError("Zero-transition identity metadata disagrees with raster hashes")
            if before != after:
                target = failures if row["variant"] == candidate else diagnostic_failures
                target.append(f"{row['scene_class']}/{row['variant']}: neutral output differs from input")
        result[control] = {"status": "fail" if failures else ("pass" if control_keys == required else "blocked"),
                           "failures": failures, "ablation_failures": diagnostic_failures,
                           "diagnostics": len(control_keys), "expected_diagnostics": len(required)}
    return result


def decide(quality, manifest, performance=()):
    """Synthetic evidence can veto a candidate, but cannot authorize adoption."""
    records = quality["records"]
    directions = {d["id"]: d for d in manifest["directions"]}
    scenes = set(manifest["matching"]["sceneClasses"])
    expected = {(scene, d["id"], variant) for scene in scenes for d in directions.values()
                for variant in VARIANTS[d["control"]]}
    seen = [(r["scene_class"], r["direction"], r["variant"]) for r in records]
    if len(seen) != len(set(seen)) or any(pair not in expected for pair in seen):
        raise ValueError("Duplicate or unknown LC-04 quality record")
    if any(r["control"] != directions[r["direction"]]["control"] for r in records):
        raise ValueError("LC-04 record control does not match direction")
    indexed = {key: record for key, record in zip(seen, records)}
    neutral = neutral_contracts(quality, manifest)
    decisions = {}
    for control, variant in CANDIDATES.items():
        missing = list(manifest["requiredMissingUntilMeasured"])
        failures = list(neutral[control]["failures"])
        if neutral[control]["status"] == "blocked":
            missing.append("Complete -1/0/+1 transition and exact-neutral identity diagnostics")
        control_expected = {pair for pair in expected if directions[pair[1]]["control"] == control}
        control_records = [r for r in records if r["control"] == control]
        if not control_expected.issubset(indexed):
            missing.append("Incomplete synthetic acceptance and ablation matrix")
        unmatched = [f"{r['scene_class']}/{r['direction']}/{r['variant']}"
                     for r in control_records if not matched(r, manifest)]
        if unmatched:
            missing.append("Unmatched or unsupported effect targets: " + ", ".join(unmatched))
        candidate_records = [r for r in control_records if r["variant"] == variant]
        for record in candidate_records:
            if matched(record, manifest):
                failures.extend(f"{record['scene_class']}/{record['direction']}: {failure}"
                                for failure in record["critical_failures"])
        spec = manifest["primary"]
        wanted = [(scene, d["id"], variant) for scene in spec["sceneClasses"]
                  for d in manifest["directions"] if d["control"] == control and d["primary"]]
        rows = [indexed[key] for key in wanted if key in indexed]
        primary = primary_comparison(rows, spec, manifest) if len(rows) == len(wanted) else {"status": "blocked", "metric": spec["metric"]}
        if primary["status"] == "fail":
            failures.append("Matched primary halo-quality target failed")
        elif primary["status"] == "blocked":
            missing.append("Complete matched primary comparison with nonempty finite ROIs")
        ablations = {}
        for comparison in VARIANTS[control]:
            if comparison == variant:
                continue
            comparison_keys = [(scene, direction, comparison) for scene, direction, _ in wanted]
            comparison_rows = [indexed[key] for key in comparison_keys if key in indexed]
            value = primary_comparison(rows, spec, manifest, comparison_rows) if len(rows) == len(wanted) and len(comparison_rows) == len(wanted) else {"status": "blocked", "metric": spec["metric"]}
            value["required_for_adoption"] = comparison == "textureGaussianExistingDomain"
            ablations[comparison] = value
            if value["required_for_adoption"]:
                if value["status"] == "fail":
                    failures.append("Matched same-Gaussian existing-domain texture ablation failed")
                elif value["status"] == "blocked":
                    missing.append("Matched same-Gaussian existing-domain texture ablation")
        control_performance = [p for p in performance if p["control"] == control]
        expected_sizes = {tuple(size) for size in manifest["performanceBudgets"]["sizes"]}
        measured_sizes = {(p["width"], p["height"]) for p in control_performance}
        if len(measured_sizes) != len(control_performance) or not measured_sizes.issubset(expected_sizes):
            raise ValueError("Duplicate or unknown LC-04 performance size")
        for item in control_performance:
            failures.extend(f"{item['width']}x{item['height']}: {failure}" for failure in item["failures"])
        if measured_sizes != expected_sizes:
            missing.append("Complete controlled cold/warm performance and peak RSS matrix")
        if any(item.get("attributable") is not True for item in control_performance):
            missing.append("Matched per-size timing effect targets")
        decisions[control] = {"decision": "no-go" if failures else "blocked", "variant": variant,
                              "primary": primary, "ablations": ablations, "neutral_identity": neutral[control], "critical_failures": failures,
                              "missing_evidence": missing, "quality_records": len(control_records),
                              "matched_records": len(control_records) - len(unmatched),
                              "scope": "Isolated CPU reference; production presence path unchanged"}
    return decisions


def performance_comparison(control, width, height, baseline_runs, candidate_runs, manifest):
    if control not in CANDIDATES or len(baseline_runs) != len(candidate_runs):
        raise ValueError("Invalid control or different process counts")
    for run in baseline_runs + candidate_runs:
        if not finite(run.get("peak_rss_bytes")) or run["peak_rss_bytes"] <= 0:
            raise ValueError("Invalid process peak RSS")
    baseline, candidate = common.timing_summary(baseline_runs), common.timing_summary(candidate_runs)
    if baseline["input_sha256"] != candidate["input_sha256"]:
        raise ValueError("Timing adapters received different inputs")
    phases = {name: [] for name in ("process-cold", "warmup", "warm")}
    pairs = []
    for baseline_run, candidate_run in zip(baseline_runs, candidate_runs):
        if len(baseline_run["samples"]) != len(candidate_run["samples"]):
            raise ValueError("Timing schedules differ")
        for before, after in zip(baseline_run["samples"], candidate_run["samples"]):
            phase = before["phase"]
            if phase != after["phase"] or phase not in phases:
                raise ValueError("Timing phase schedules differ")
            match = effect_matches(before.get("effect_strength"), after.get("effect_strength"), manifest)
            phases[phase].append(match)
            pairs.append({"phase": phase, "picedit": before.get("effect_strength"),
                          "lightcraft": after.get("effect_strength"), "matched": match})
    all_matched = all(values and all(values) for values in phases.values())
    numerators = {"cold_latency_ratio": candidate["process_cold"]["median_ms"],
                  "warm_latency_ratio": candidate["warm"]["median_ms"], "peak_rss_ratio": candidate["peak_rss_bytes"]}
    denominators = {"cold_latency_ratio": baseline["process_cold"]["median_ms"],
                    "warm_latency_ratio": baseline["warm"]["median_ms"], "peak_rss_ratio": baseline["peak_rss_bytes"]}
    if any(not finite(v) or v <= 0 for v in denominators.values()) or any(not finite(v) or v < 0 for v in numerators.values()):
        raise ValueError("Invalid timing or memory measurement")
    ratios = {key: value / denominators[key] for key, value in numerators.items()}
    budgets = manifest["performanceBudgets"]
    limits = {"cold_latency_ratio": budgets["maximumColdLatencyRatio"], "warm_latency_ratio": budgets["maximumWarmLatencyRatio"],
              "peak_rss_ratio": budgets["maximumPeakRSSRatio"]}
    attribution = {"cold_latency_ratio": bool(phases["process-cold"]) and all(phases["process-cold"]),
                   "warm_latency_ratio": bool(phases["warm"]) and all(phases["warm"]), "peak_rss_ratio": all_matched}
    exceeded = {key: f"{key} {ratios[key]:.6g} exceeds {limit}" for key, limit in limits.items() if ratios[key] > limit}
    return {"control": control, "width": width, "height": height, "picedit": baseline, "lightcraft": candidate,
            "ratios": ratios, "attributable": all_matched, "phase_attribution": attribution,
            "effect_strength_pairs": pairs, "budget_exceedances": list(exceeded.values()),
            "failures": [failure for key, failure in exceeded.items() if attribution[key]],
            "note": "Isolated CPU reference including conversion/readback; no accelerated-path claim. Warm samples share process caches."}


def views(output, records):
    style = "body{font:15px system-ui;margin:2rem;background:#eee;color:#222}section{margin:2rem 0}figure{display:inline-block;margin:8px}img{width:384px;image-rendering:pixelated}figcaption{max-width:384px}"
    labeled = [f"<!doctype html><meta charset='utf-8'><title>LC-04 comparisons</title><style>{style}</style><h1>LC-04 comparisons</h1><p>Clarity and texture are independent. Same-Gaussian texture ablations separate existing gamma/additive domain, log detail, and detail limiting/taming. Unmatched results cannot establish gains or regressions.</p>"]
    blind = [f"<!doctype html><meta charset='utf-8'><title>LC-04 blind pairs</title><style>{style}</style><h1>LC-04 blind pairs</h1><p>Record preference and defects before opening blind-key.json. Generated pairs are not completed visual approval.</p>"]
    key = []
    (output / "blind").mkdir()
    for number, record in enumerate(records, 1):
        directory = Path("quality") / record["directory"]
        if directory.is_absolute() or ".." in directory.parts:
            raise ValueError("Invalid quality image directory")
        title = html.escape(f"{record['fixture']} · {record['direction']} · {record['variant']} · matched={record['matched']}")
        labeled.append(f"<section><h2>{title}</h2>")
        for filename, label in (("input.png", "Input"), ("picedit.png", "PicEdit"), ("lightcraft.png", "Matched candidate"),
                                ("same-values.png", "Candidate same values"), ("difference.png", "Difference ×8"),
                                ("dark.png", "Dark composite"), ("light.png", "Light composite")):
            path = directory / filename
            if not (output / path).is_file():
                raise ValueError(f"Missing image artifact: {path}")
            labeled.append(f"<figure><img src='{html.escape(path.as_posix(), quote=True)}'><figcaption>{label}</figcaption></figure>")
        labeled.append("</section>")
        pair = [("picedit.png", "picedit"), ("lightcraft.png", record["variant"])]
        if hashlib.sha256(f"lc04-blind-v1:{record['fixture']}:{record['direction']}:{record['variant']}".encode()).digest()[0] % 2:
            pair.reverse()
        blind.append(f"<section><h2>Pair {number:03d}</h2>")
        entry = {"pair": number, "fixture": record["fixture"], "direction": record["direction"], "variant": record["variant"], "matched": record["matched"]}
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
        raise ValueError("LC-04 has no registered real-photo ROIs; --real-manifest remains an LC-01 diagnostic option")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    protocol_source = SOURCE / "lc04-manifest.json"
    manifest = json.loads(protocol_source.read_text())
    frozen = output / protocol_source.name
    frozen.write_bytes(protocol_source.read_bytes())
    sources = list((ROOT / "Sources").rglob("*.swift"))
    sources += [ROOT / "Package.swift", ROOT / "Package.resolved", SOURCE / "run.py", Path(__file__),
                ROOT / "scripts/evaluate-lightcraft.sh", ROOT / "scripts/build-developer-tool.sh",
                SOURCE / "THIRD-PARTY-NOTICES.txt", SOURCE / "candidate-registry.json"]
    sources += [p for folder in ("lc03-reference-oracle", "lc04-reference-oracle", "licenses")
                for p in (SOURCE / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    hashes = {str(p.relative_to(ROOT)): common.digest(p) for p in sorted(set(sources)) if p.is_file()}
    hardware = common.command(["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini"])
    hardware = "\n".join(line for line in hardware.splitlines() if not any(k in line for k in ("Serial Number", "Hardware UUID", "Provisioning UDID")))
    budgets = manifest["performanceBudgets"]
    metadata = {"schema_version": 1, "candidate": "LC-04", "base_commit": common.command(["git", "rev-parse", "HEAD"]),
                "source_sha256": hashes, "binary_sha256": common.digest(args.binary), "manifest_sha256": common.digest(frozen),
                "toolchain": common.command(["xcrun", "swift", "--version"]), "os": common.command(["sw_vers"]),
                "hardware": hardware, "architecture": platform.machine(), "timing_concurrency": 1,
                "configuration": "release, existing editing harness", "backend": "PicEdit: Core Image automatic; reference: bounded CPU",
                "timing_order": "Per control and size, paired separate processes; alternate first adapter each repetition. All measurements serial to avoid CPU/GPU/memory contention.",
                "sizes": budgets["sizes"], "repetitions": budgets["minimumColdProcesses"],
                "warm_samples_per_process": budgets["minimumWarmSamplesPerProcess"], "warmups_per_process": 1,
                "timing_scene": manifest["performanceSceneClass"], "real_inputs": "none"}
    common.write_json(output / "environment.json", metadata)
    invocations, calibration_hash = [], None
    calibration = output / "tuning/calibration.json"

    def unchanged():
        if common.digest(protocol_source) != metadata["manifest_sha256"] or common.digest(frozen) != metadata["manifest_sha256"]:
            raise ValueError("LC-04 protocol changed during evaluation")
        if common.digest(args.binary) != metadata["binary_sha256"] or any(common.digest(ROOT / p) != h for p, h in hashes.items()):
            raise ValueError("LC-04 binary or sources changed during evaluation")
        if calibration_hash is not None and common.digest(calibration) != calibration_hash:
            raise ValueError("Calibration changed after tuning was frozen")

    def invoke(mode, name, width=None, height=None, adapter=None):
        unchanged()
        cmd = [str(args.binary.resolve()), "--scenario", "evaluation", "--evaluation-mode", "detail-" + mode,
               "--manifest", str(frozen), "--output", str(output / name), "--width", str(width or manifest["qualityWidth"]),
               "--height", str(height or manifest["qualityHeight"]), "--iterations", str(budgets["minimumWarmSamplesPerProcess"])]
        if mode != "tune":
            cmd += ["--calibration", str(calibration)]
        if adapter:
            cmd += ["--adapter", adapter]
        invocations.append(cmd)
        common.write_json(output / "commands.json", invocations)
        print(f"LC-04: {name}", flush=True)
        with (output / f"{name}.log").open("w") as log:
            subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        unchanged()

    invoke("tune", "tuning")
    tuning = json.loads(calibration.read_text())
    if tuning["manifestSHA256"] != metadata["manifest_sha256"]:
        raise ValueError("Tuning used a different protocol")
    calibration_hash = common.digest(calibration)
    metadata["calibration_sha256"] = calibration_hash
    common.write_json(output / "environment.json", metadata)
    invoke("quality", "quality")
    quality = json.loads((output / "quality/quality.json").read_text())
    if quality["manifest_sha256"] != metadata["manifest_sha256"] or quality["calibration_sha256"] != calibration_hash:
        raise ValueError("Acceptance used a different frozen protocol or calibration")
    views(output, quality["records"])
    performance = []
    for control in CANDIDATES:
        for width, height in budgets["sizes"]:
            adapters = {"picedit": [], "lightcraft": []}
            # Independent development/tests can run concurrently; measurements
            # cannot: each adapter must have exclusive compute/memory resources.
            for number in range(1, budgets["minimumColdProcesses"] + 1):
                order = ("picedit", "lightcraft") if number % 2 else ("lightcraft", "picedit")
                for adapter in order:
                    name = f"timing-{control}-{width}-{adapter}-{number}"
                    invoke("timing", name, width, height, f"{adapter}-{control}")
                    run = json.loads((output / name / "timing.json").read_text())
                    if run.get("adapter") != f"{adapter}-{control}":
                        raise ValueError("Timing adapter metadata mismatch")
                    adapters[adapter].append(run)
            performance.append(performance_comparison(control, width, height, adapters["picedit"], adapters["lightcraft"], manifest))
    invoke("scale", "scale", *budgets["sizes"][-1])
    unchanged()
    decisions = decide(quality, manifest, performance)
    summary = {"schema_version": 1, "candidate": "LC-04", "decisions": decisions, "timings": performance,
               "manifest_sha256": metadata["manifest_sha256"], "calibration_sha256": calibration_hash,
               "quality": "quality/quality.json", "scale": "scale/scale.json", "production_changed": False}
    common.write_json(output / "summary.json", summary)
    print(f"LC-04 complete ({', '.join(c + ': ' + d['decision'] for c, d in decisions.items())}): {output / 'summary.json'}", flush=True)

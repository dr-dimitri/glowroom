#!/usr/bin/env python3
"""Frozen LC-05 protocol: input-relative saturation and vibrance evaluation."""
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
CONTROLS = ("vibrance", "saturation")
VARIANTS = ("gamutMappedSRGB", "unbounded")
CANDIDATE = "gamutMappedSRGB"


def matches(record, manifest):
    return record.get("matched") is True and effect_matches(record.get("effect_target"), record.get("effect_measured"), manifest)


def valid_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def failures_field(record):
    value = record.get("contract_failures")
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError("Missing or invalid LC-05 contract failure evidence")
    return value


def metric_contracts(record, manifest):
    """These numerical/alpha/gray contracts do not need effect matching."""
    if record.get("finite") is not True:
        raise ValueError("Missing finite-output contract evidence")
    metrics = record.get("candidate_metrics", record.get("metrics"))
    if not isinstance(metrics, dict) or not metrics or any(not finite(value) for value in metrics.values()):
        raise ValueError("Missing or nonfinite LC-05 contract metrics")
    required = ("alpha_error", "neutral_sample_count", "neutral_chroma_max", "hidden_rgb_error")
    if any(not finite(metrics.get(key)) or metrics[key] < 0 for key in required):
        raise ValueError("Incomplete LC-05 alpha/gray contract metrics")
    failures = list(failures_field(record))
    if metrics["alpha_error"] > manifest["contracts"]["alphaTolerance"]:
        failures.append("alpha_error")
    if metrics["hidden_rgb_error"] > 0:
        failures.append("hidden_rgb_error")
    if metrics["neutral_sample_count"] > 0 and metrics["neutral_chroma_max"] > manifest["contracts"]["maximumNeutralChroma"]:
        failures.append("neutral_chroma_max")
    return sorted(set(failures))


def contracts(quality, manifest):
    scenes = manifest["matching"]["sceneClasses"]
    expected_zero = {(scene, control, variant, value) for scene in scenes for control in CONTROLS
                     for variant in VARIANTS for value in manifest["contracts"]["neutralValues"]}
    zero = quality.get("zero_diagnostics", [])
    zero_keys = [(r["scene_class"], r["control"], r["variant"], r["value"]) for r in zero]
    if len(set(zero_keys)) != len(zero_keys) or any(key not in expected_zero for key in zero_keys):
        raise ValueError("Duplicate or unknown LC-05 zero-transition diagnostic")
    expected_desaturation = {(scene, variant) for scene in scenes for variant in VARIANTS}
    desaturation = quality.get("full_desaturation_diagnostics", [])
    desaturation_keys = [(r["scene_class"], r["variant"]) for r in desaturation]
    if len(set(desaturation_keys)) != len(desaturation_keys) or any(key not in expected_desaturation for key in desaturation_keys):
        raise ValueError("Duplicate or unknown LC-05 full-desaturation diagnostic")
    result = {}
    for control in CONTROLS:
        decisive, diagnostic = [], []
        required = {key for key in expected_zero if key[1] == control}
        present = {key for key in zero_keys if key[1] == control}
        missing = [] if present == required else ["Complete -1/0/+1 diagnostic and neutral identity matrix"]
        for row in zero:
            if row["control"] != control:
                continue
            problems = metric_contracts(row, manifest)
            if row["value"] == 0:
                before, after = row.get("input_sha256"), row.get("output_sha256")
                if not valid_hash(before) or not valid_hash(after) or row.get("identity") is not (before == after):
                    raise ValueError("Invalid LC-05 exact-zero identity provenance")
                if before != after:
                    problems.append("zero_identity")
            target = decisive if row["variant"] == CANDIDATE else diagnostic
            target.extend(f"{row['scene_class']}/{row['variant']}/{row['value']}: {failure}" for failure in sorted(set(problems)))
        if control == "saturation":
            if set(desaturation_keys) != expected_desaturation:
                missing.append("Complete independent saturation=-100 achromatic matrix")
            for row in desaturation:
                problems = metric_contracts(row, manifest)
                chroma = row["metrics"].get("output_chroma_max")
                if not finite(chroma) or chroma < 0:
                    raise ValueError("Invalid full-desaturation chroma evidence")
                if chroma > manifest["contracts"]["maximumNeutralChroma"]:
                    problems.append("full_desaturation_chroma")
                target = decisive if row["variant"] == CANDIDATE else diagnostic
                target.extend(f"{row['scene_class']}/{row['variant']}/-100: {failure}" for failure in sorted(set(problems)))
        for row in quality["records"]:
            if row["control"] == control:
                target = decisive if row["variant"] == CANDIDATE else diagnostic
                target.extend(f"{row['scene_class']}/{row['direction']}/{row['variant']}: {failure}"
                              for failure in metric_contracts(row, manifest))
        result[control] = {"status": "fail" if decisive else ("blocked" if missing else "pass"),
                           "failures": decisive, "diagnostic_failures": diagnostic, "missing_evidence": missing,
                           "zero_diagnostics": len(present), "expected_zero_diagnostics": len(required),
                           "full_desaturation_diagnostics": len(desaturation) if control == "saturation" else 0}
    return result


def primary_comparison(rows, expected_count, manifest):
    spec = manifest["primary"]
    result = {"status": "blocked", "reference": "original input", "metrics": {}}
    if len(rows) != expected_count or not rows or any(not matches(row, manifest) for row in rows):
        return result
    for row in rows:
        for metrics in (row["baseline_metrics"], row["candidate_metrics"]):
            if (not finite(metrics.get("visible_weight")) or metrics["visible_weight"] <= 0 or
                not finite(metrics.get("hue_sample_count")) or metrics["hue_sample_count"] <= 0 or
                not finite(metrics.get("hue_missing_count")) or metrics["hue_missing_count"] != 0 or
                any(not finite(metrics.get(key)) or metrics[key] < 0 for key in spec["metrics"])):
                return result
    passed, informative = True, 0
    for metric, limits in spec["metrics"].items():
        baseline = sum(row["baseline_metrics"][metric] for row in rows) / len(rows)
        candidate = sum(row["candidate_metrics"][metric] for row in rows) / len(rows)
        has_signal = baseline > limits["baselineFloor"]
        improvement = (baseline - candidate) / baseline if has_signal else None
        regressions = [f"{row['scene_class']}/{row['direction']}: +{row['candidate_metrics'][metric] - row['baseline_metrics'][metric]:.9g}"
                       for row in rows if row["candidate_metrics"][metric] - row["baseline_metrics"][metric] > limits["maximumPerCaseRegression"]]
        metric_pass = (improvement >= spec["minimumRelativeImprovement"] if has_signal
                       else candidate <= limits["baselineFloor"]) and not regressions
        informative += int(has_signal)
        passed = passed and metric_pass
        result["metrics"][metric] = {"status": "pass" if metric_pass else "fail", "baseline_mean": baseline,
                                     "candidate_mean": candidate, "informative": has_signal,
                                     "relative_improvement": improvement, "regressions": regressions}
    result.update(status="pass" if passed and informative else "fail", informative_targets=informative,
                  note="Equal scene/direction weights; deterministic fixtures, no pixel-independence or statistical-significance claim")
    return result


def critical_evidence(record, direction, manifest):
    """Recompute input-relative regressions; never trust a failure label alone."""
    before, after, limits = record["baseline_metrics"], record["candidate_metrics"], manifest["criticalLimits"]
    failures, missing = [], []
    pairs = [("lightness_drift_mean", "lightnessMeanIncrease"), ("gamut_fraction", "gamutFractionIncrease"),
             ("clipping_fraction", "clippingFractionIncrease")]
    if not (direction["control"] == "saturation" and direction["value"] == -100):
        if all(finite(values.get("hue_sample_count")) and values["hue_sample_count"] > 0 for values in (before, after)):
            pairs += [("hue_drift_max_degrees", "hueMaxIncreaseDegrees"), ("hue_loss_fraction", "hueLossFractionIncrease")]
        else:
            missing.append("input-defined hue support")
        if record["scene_class"] == "color-gradients":
            if all(finite(values.get("gradation_sample_count")) and values["gradation_sample_count"] > 0 for values in (before, after)):
                pairs += [("gradation_collapse_fraction", "gradationCollapseIncrease"), ("gradation_reversal_fraction", "gradationReversalIncrease")]
            else:
                missing.append("known color-gradation pairs")
    for metric, limit in pairs:
        if any(not finite(values.get(metric)) or values[metric] < 0 for values in (before, after)):
            missing.append(metric)
        elif after[metric] - before[metric] > limits[limit]:
            failures.append(metric)
    if not finite(after.get("alpha_error")) or after["alpha_error"] < 0:
        missing.append("alpha_error")
    elif after["alpha_error"] > limits["alphaError"]:
        failures.append("alpha_error")
    return failures, missing


def decide(quality, manifest, performance=()):
    directions = {d["id"]: d for d in manifest["directions"]}
    scenes = manifest["matching"]["sceneClasses"]
    expected = {(scene, direction, variant) for scene in scenes for direction in directions for variant in VARIANTS}
    records = quality["records"]
    keys = [(r["scene_class"], r["direction"], r["variant"]) for r in records]
    if len(set(keys)) != len(keys) or any(key not in expected for key in keys):
        raise ValueError("Duplicate or unknown LC-05 quality record")
    if any(r["control"] != directions[r["direction"]]["control"] for r in records):
        raise ValueError("LC-05 quality control/direction mismatch")
    if any(p.get("control") not in CONTROLS for p in performance):
        raise ValueError("Unknown LC-05 performance control")
    contract_evidence = contracts(quality, manifest)
    indexed = dict(zip(keys, records))
    decisions = {}
    for control in CONTROLS:
        failures = list(contract_evidence[control]["failures"])
        missing = list(manifest["requiredMissingUntilMeasured"]) + contract_evidence[control]["missing_evidence"]
        expected_control = {key for key in expected if directions[key[1]]["control"] == control}
        control_records = [r for r in records if r["control"] == control]
        if not expected_control.issubset(indexed):
            missing.append("Incomplete synthetic acceptance and output-policy matrix")
        unmatched = [f"{r['scene_class']}/{r['direction']}/{r['variant']}" for r in control_records if not matches(r, manifest)]
        if unmatched:
            missing.append("Unmatched or unsupported effect targets: " + ", ".join(unmatched))
        candidate_records = [r for r in control_records if r["variant"] == CANDIDATE]
        for record in candidate_records:
            if matches(record, manifest):
                failure_list = record.get("critical_failures")
                if not isinstance(failure_list, list) or any(not isinstance(item, str) for item in failure_list):
                    raise ValueError("Invalid LC-05 critical failure evidence")
                derived, absent = critical_evidence(record, directions[record["direction"]], manifest)
                failures.extend(f"{record['scene_class']}/{record['direction']}: {failure}" for failure in derived)
                if absent:
                    missing.append(f"{record['scene_class']}/{record['direction']}: missing critical evidence: " + ", ".join(absent))
        wanted = [(scene, d["id"]) for scene in manifest["primary"]["sceneClasses"]
                  for d in manifest["directions"] if d["control"] == control and d["primary"]]
        comparisons = {}
        for variant in VARIANTS:
            rows = [indexed[(scene, direction, variant)] for scene, direction in wanted if (scene, direction, variant) in indexed]
            comparisons[variant] = primary_comparison(rows, len(wanted), manifest)
        primary = comparisons[CANDIDATE]
        if primary["status"] == "fail":
            failures.append("Complete matched input-relative hue/lightness target failed")
        elif primary["status"] == "blocked":
            missing.append("Complete matched primary matrix with finite metrics and complete input-defined hue support")
        timings = [p for p in performance if p["control"] == control]
        wanted_sizes = {tuple(size) for size in manifest["performanceBudgets"]["sizes"]}
        measured_sizes = {(p["width"], p["height"]) for p in timings}
        if len(measured_sizes) != len(timings) or not measured_sizes.issubset(wanted_sizes):
            raise ValueError("Duplicate or unknown LC-05 performance size")
        for item in timings:
            failures.extend(f"{item['width']}x{item['height']}: {failure}" for failure in item["failures"])
        if measured_sizes != wanted_sizes:
            missing.append("Complete controlled cold/warm performance and peak RSS matrix")
        if any(item.get("attributable") is not True for item in timings):
            missing.append("Matched per-size timing effect targets")
        decisions[control] = {"decision": "no-go" if failures else "blocked", "variant": CANDIDATE,
                              "primary": primary, "diagnostic_unbounded": comparisons["unbounded"],
                              "contracts": contract_evidence[control], "critical_failures": failures,
                              "missing_evidence": missing, "quality_records": len(control_records),
                              "matched_records": len(control_records) - len(unmatched),
                              "scope": "Isolated mapped CPU color reference; production graph/settings unchanged"}
    return decisions


def performance_comparison(control, width, height, baseline_runs, candidate_runs, manifest):
    if control not in CONTROLS or len(baseline_runs) != len(candidate_runs):
        raise ValueError("Invalid control or different process counts")
    for adapter, runs in (("glowroom", baseline_runs), ("lightcraft", candidate_runs)):
        for run in runs:
            if (run.get("width"), run.get("height"), run.get("control"), run.get("adapter")) != (width, height, control, f"{adapter}-{control}"):
                raise ValueError("Timing geometry/control/adapter metadata mismatch")
            if not finite(run.get("peak_rss_bytes")) or run["peak_rss_bytes"] <= 0:
                raise ValueError("Invalid process peak RSS")
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
            match = effect_matches(before.get("effect_strength"), after.get("effect_strength"), manifest)
            phases[phase].append(match)
            pairs.append({"phase": phase, "glowroom": before.get("effect_strength"), "lightcraft": after.get("effect_strength"), "matched": match})
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
    return {"control": control, "width": width, "height": height, "glowroom": baseline, "lightcraft": candidate,
            "ratios": ratios, "attributable": all_matched, "phase_attribution": attribution, "effect_strength_pairs": pairs,
            "budget_exceedances": list(exceeded.values()), "failures": [value for key, value in exceeded.items() if attribution[key]],
            "note": "Mapped isolated CPU reference including conversion/readback; no accelerated-path claim. Warm samples share process caches."}


def views(output, records):
    style = "body{font:15px system-ui;margin:2rem;background:#eee;color:#222}section{margin:2rem 0}figure{display:inline-block;margin:8px}img{width:384px;image-rendering:pixelated}figcaption{max-width:384px}"
    labeled = [f"<!doctype html><meta charset='utf-8'><title>LC-05 comparisons</title><style>{style}</style><h1>LC-05 comparisons</h1><p>Saturation and vibrance have separate decisions. Quality measures hue and lightness against the input. Glowroom compatibility and unbounded color output remain diagnostics.</p>"]
    blind = [f"<!doctype html><meta charset='utf-8'><title>LC-05 blind pairs</title><style>{style}</style><h1>LC-05 blind pairs</h1><p>Record preference and defects before opening blind-key.json. Generated pairs are not completed visual approval.</p>"]
    key = []
    (output / "blind").mkdir()
    for number, record in enumerate(records, 1):
        directory = Path("quality") / record["directory"]
        if directory.is_absolute() or ".." in directory.parts:
            raise ValueError("Invalid quality image directory")
        title = html.escape(f"{record['fixture']} · {record['direction']} · {record['variant']} · matched={record['matched']}")
        labeled.append(f"<section><h2>{title}</h2>")
        for filename, label in (("input.png", "Input"), ("glowroom.png", "Glowroom"), ("lightcraft.png", "Matched candidate"),
                                ("same-values.png", "Candidate same values"), ("difference.png", "Difference ×8"),
                                ("dark.png", "Dark composite"), ("light.png", "Light composite")):
            path = directory / filename
            if not (output / path).is_file():
                raise ValueError(f"Missing image artifact: {path}")
            labeled.append(f"<figure><img src='{html.escape(path.as_posix(), quote=True)}'><figcaption>{label}</figcaption></figure>")
        labeled.append("</section>")
        pair = [("glowroom.png", "glowroom"), ("lightcraft.png", record["variant"])]
        if hashlib.sha256(f"lc05-blind-v1:{record['fixture']}:{record['direction']}:{record['variant']}".encode()).digest()[0] % 2:
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
        raise ValueError("LC-05 has no registered real-photo ROIs; --real-manifest remains an LC-01 diagnostic option")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    protocol_source = SOURCE / "lc05-manifest.json"
    manifest = json.loads(protocol_source.read_text())
    frozen = output / protocol_source.name
    frozen.write_bytes(protocol_source.read_bytes())
    sources = list((ROOT / "Sources").rglob("*.swift"))
    sources += [ROOT / "Package.swift", ROOT / "Package.resolved", SOURCE / "run.py", SOURCE / "lc04.py", Path(__file__),
                ROOT / "scripts/evaluate-lightcraft.sh", ROOT / "scripts/build-developer-tool.sh",
                SOURCE / "THIRD-PARTY-NOTICES.txt", SOURCE / "candidate-registry.json"]
    sources += [p for folder in ("lc05-reference-oracle", "licenses") for p in (SOURCE / folder).rglob("*")
                if p.is_file() and "__pycache__" not in p.parts]
    hashes = {str(p.relative_to(ROOT)): common.digest(p) for p in sorted(set(sources)) if p.is_file()}
    hardware = common.command(["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini"])
    hardware = "\n".join(line for line in hardware.splitlines() if not any(k in line for k in ("Serial Number", "Hardware UUID", "Provisioning UDID")))
    budgets = manifest["performanceBudgets"]
    metadata = {"schema_version": 1, "candidate": "LC-05", "base_commit": common.command(["git", "rev-parse", "HEAD"]),
                "source_sha256": hashes, "binary_sha256": common.digest(args.binary), "manifest_sha256": common.digest(frozen),
                "toolchain": common.command(["xcrun", "swift", "--version"]), "os": common.command(["sw_vers"]),
                "hardware": hardware, "architecture": platform.machine(), "timing_concurrency": 1,
                "configuration": "release, existing editing harness", "backend": "Glowroom: Core Image automatic; mapped reference: bounded CPU",
                "timing_order": "Per control and size, paired separate processes; alternate first adapter each repetition. Serial measurements avoid CPU/GPU/memory contention.",
                "sizes": budgets["sizes"], "repetitions": budgets["minimumColdProcesses"],
                "warm_samples_per_process": budgets["minimumWarmSamplesPerProcess"], "warmups_per_process": 1,
                "timing_scene": manifest["performanceSceneClass"], "real_inputs": "none"}
    common.write_json(output / "environment.json", metadata)
    invocations, calibration_hash = [], None
    calibration = output / "tuning/calibration.json"

    def unchanged():
        if common.digest(protocol_source) != metadata["manifest_sha256"] or common.digest(frozen) != metadata["manifest_sha256"]:
            raise ValueError("LC-05 protocol changed during evaluation")
        if common.digest(args.binary) != metadata["binary_sha256"] or any(common.digest(ROOT / p) != h for p, h in hashes.items()):
            raise ValueError("LC-05 binary or sources changed during evaluation")
        if calibration_hash is not None and common.digest(calibration) != calibration_hash:
            raise ValueError("Calibration changed after tuning was frozen")

    def invoke(mode, name, width=None, height=None, adapter=None):
        unchanged()
        cmd = [str(args.binary.resolve()), "--scenario", "evaluation", "--evaluation-mode", "color-" + mode,
               "--manifest", str(frozen), "--output", str(output / name), "--width", str(width or manifest["qualityWidth"]),
               "--height", str(height or manifest["qualityHeight"]), "--iterations", str(budgets["minimumWarmSamplesPerProcess"])]
        if mode != "tune":
            cmd += ["--calibration", str(calibration)]
        if adapter:
            cmd += ["--adapter", adapter]
        invocations.append(cmd)
        common.write_json(output / "commands.json", invocations)
        print(f"LC-05: {name}", flush=True)
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
    # Validate contracts/matrix before expensive timing; a no-go is still a
    # complete experiment, whereas malformed evidence must abort the run.
    decide(quality, manifest)
    views(output, quality["records"])
    performance = []
    for control in CONTROLS:
        for width, height in budgets["sizes"]:
            adapters = {"glowroom": [], "lightcraft": []}
            for number in range(1, budgets["minimumColdProcesses"] + 1):
                # Development can be parallel; competing measurements cannot.
                order = ("glowroom", "lightcraft") if number % 2 else ("lightcraft", "glowroom")
                for adapter in order:
                    name = f"timing-{control}-{width}-{adapter}-{number}"
                    invoke("timing", name, width, height, f"{adapter}-{control}")
                    adapters[adapter].append(json.loads((output / name / "timing.json").read_text()))
            performance.append(performance_comparison(control, width, height, adapters["glowroom"], adapters["lightcraft"], manifest))
    invoke("scale", "scale", *budgets["sizes"][-1])
    unchanged()
    decisions = decide(quality, manifest, performance)
    summary = {"schema_version": 1, "candidate": "LC-05", "decisions": decisions, "timings": performance,
               "manifest_sha256": metadata["manifest_sha256"], "calibration_sha256": calibration_hash,
               "quality": "quality/quality.json", "scale": "scale/scale.json", "production_changed": False}
    common.write_json(output / "summary.json", summary)
    print(f"LC-05 complete ({', '.join(c + ': ' + d['decision'] for c, d in decisions.items())}): {output / 'summary.json'}", flush=True)

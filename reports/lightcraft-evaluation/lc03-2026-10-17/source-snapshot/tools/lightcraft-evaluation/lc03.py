#!/usr/bin/env python3
"""Frozen LC-03 protocol and serial orchestration of the editing harness."""
import hashlib
import html
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess

import run as common

ROOT = common.ROOT
SOURCE = common.SOURCE


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def effect_matches(target, measured, manifest):
    limits = manifest["matching"]
    return (finite(target) and finite(measured) and target * measured > 0
            and abs(target) >= limits["minimumAbsoluteTarget"]
            and abs(target - measured) <= max(limits["maximumAbsoluteDeltaError"],
                                              abs(target) * limits["maximumRelativeDeltaError"]))


def decide(quality, manifest, performance=()):
    """Only complete, matched evidence can prove a gain or a technical no-go."""
    records = quality["records"]
    scenes = set(manifest["matching"]["sceneClasses"])
    directions = {d["id"]: d for d in manifest["directions"]}
    expected = {(scene, direction) for scene in scenes for direction in directions}
    seen = [(r["scene_class"], r["direction"]) for r in records]
    if len(seen) != len(set(seen)) or any(pair not in expected for pair in seen):
        raise ValueError("Duplicate or unknown LC-03 quality record")
    missing = list(manifest["requiredMissingUntilMeasured"])
    if set(seen) != expected:
        missing.append("Incomplete synthetic acceptance matrix")
    unmatched = [f"{r['scene_class']}/{r['direction']}" for r in records if r.get("matched") is not True]
    if unmatched:
        missing.append("Unmatched or unsupported effect targets: " + ", ".join(unmatched))
    failures = []
    for record in records:
        if record.get("matched") is True:
            failures.extend(f"{record['scene_class']}/{record['direction']}: {failure}"
                            for failure in record["critical_failures"])

    wanted = {d["id"] for d in manifest["directions"] if d["primary"]}
    primary_rows = [r for r in records if r["scene_class"] == manifest["primary"]["sceneClass"]
                    and r["direction"] in wanted]
    metric = manifest["primary"]["metric"]
    valid = len(primary_rows) == len(wanted) and all(r.get("matched") is True for r in primary_rows)
    for record in primary_rows:
        for key in ("baseline_metrics", "candidate_metrics"):
            values = record[key]
            valid = valid and all(finite(values.get(k)) and values[k] >= 0
                                  for k in (metric, "bright_line_error", "dark_line_error"))
            valid = valid and all(finite(values.get(k)) and values[k] > 0
                                  for k in ("bright_line_count", "dark_line_count"))
    primary = {"status": "blocked", "metric": metric, "required_directions": sorted(wanted)}
    if valid:
        baseline = sum(r["baseline_metrics"][metric] for r in primary_rows) / len(primary_rows)
        candidate = sum(r["candidate_metrics"][metric] for r in primary_rows) / len(primary_rows)
        improvement = (baseline - candidate) / baseline if baseline > 0 else 0
        regressions = []
        for record in primary_rows:
            for half in ("bright_line_error", "dark_line_error"):
                change = record["candidate_metrics"][half] - record["baseline_metrics"][half]
                if change > manifest["primary"]["maximumPerCaseRegression"]:
                    regressions.append(f"{record['direction']}/{half}: +{change:.9g}")
        passed = improvement >= manifest["primary"]["minimumRelativeImprovement"] and not regressions
        primary.update(status="pass" if passed else "fail", baseline_mean=baseline,
                       candidate_mean=candidate, relative_improvement=improvement, regressions=regressions)
        if not passed:
            failures.append("Matched primary detail-preservation target failed")
    else:
        missing.append("Complete matched moderate fine-line comparison with nonempty finite ROIs")

    for item in performance:
        # performance_comparison emits failures only for the matching phases;
        # unmatched budget exceedances are separate, non-gating diagnostics.
        failures.extend(f"{item['width']}x{item['height']}: {failure}" for failure in item["failures"])
    if not performance:
        missing.append("Controlled cold/warm performance and peak RSS")
    elif any(item.get("attributable") is not True for item in performance):
        missing.append("Matched per-size timing effect targets")
    # Real-photo, visual and production-integration evidence is deliberately
    # absent from this isolated experiment. Never manufacture a Go from it.
    return {"decision": "no-go" if failures else "blocked", "primary": primary,
            "critical_failures": failures, "missing_evidence": missing,
            "matched_records": len(records) - len(unmatched), "quality_records": len(records),
            "scope": "Pinned isolated CPU tone candidate; no production-path integration or accelerated-path claim"}


def performance_comparison(width, height, baseline_runs, candidate_runs, manifest):
    baseline = common.timing_summary(baseline_runs)
    candidate = common.timing_summary(candidate_runs)
    if baseline["input_sha256"] != candidate["input_sha256"]:
        raise ValueError("Timing adapters received different inputs")
    # The native mode records matching at each size. A quality-only match at
    # 512 px cannot establish a full-resolution performance comparison.
    phases = {name: [] for name in ("process-cold", "warmup", "warm")}
    strength_pairs = []
    for baseline_run, candidate_run in zip(baseline_runs, candidate_runs):
        if len(baseline_run["samples"]) != len(candidate_run["samples"]):
            raise ValueError("Timing schedules differ")
        for baseline_sample, candidate_sample in zip(baseline_run["samples"], candidate_run["samples"]):
            phase = baseline_sample["phase"]
            if phase != candidate_sample["phase"] or phase not in phases:
                raise ValueError("Timing phase schedules differ")
            matched = effect_matches(baseline_sample.get("effect_strength"), candidate_sample.get("effect_strength"), manifest)
            phases[phase].append(matched)
            strength_pairs.append({"phase": phase, "picedit": baseline_sample.get("effect_strength"),
                                   "lightcraft": candidate_sample.get("effect_strength"), "matched": matched})
    cold_matched = bool(phases["process-cold"]) and all(phases["process-cold"])
    warm_matched = bool(phases["warm"]) and all(phases["warm"])
    all_matched = all(values and all(values) for values in phases.values())
    numerators = {"cold_latency_ratio": candidate["process_cold"]["median_ms"],
                  "warm_latency_ratio": candidate["warm"]["median_ms"],
                  "peak_rss_ratio": candidate["peak_rss_bytes"]}
    denominators = {"cold_latency_ratio": baseline["process_cold"]["median_ms"],
                    "warm_latency_ratio": baseline["warm"]["median_ms"],
                    "peak_rss_ratio": baseline["peak_rss_bytes"]}
    if any(not finite(v) or v <= 0 for v in denominators.values()):
        raise ValueError("Invalid timing baseline")
    ratios = {key: value / denominators[key] for key, value in numerators.items()}
    budgets = manifest["performanceBudgets"]
    limits = {"cold_latency_ratio": budgets["maximumColdLatencyRatio"],
              "warm_latency_ratio": budgets["maximumWarmLatencyRatio"],
              "peak_rss_ratio": budgets["maximumPeakRSSRatio"]}
    attribution = {"cold_latency_ratio": cold_matched, "warm_latency_ratio": warm_matched, "peak_rss_ratio": all_matched}
    exceeded = {key: f"{key} {ratios[key]:.6g} exceeds {limit}" for key, limit in limits.items() if ratios[key] > limit}
    failures = [failure for key, failure in exceeded.items() if attribution[key]]
    return {"width": width, "height": height, "picedit": baseline, "lightcraft": candidate,
            "ratios": ratios, "attributable": all_matched, "phase_attribution": attribution,
            "effect_strength_pairs": strength_pairs, "budget_exceedances": list(exceeded.values()), "failures": failures,
            "note": "Ratios describe this isolated CPU implementation and its conversion/readback path, not a hypothetical accelerated implementation."}


def views(output, records):
    style = "body{font:15px system-ui;margin:2rem;background:#eee;color:#222}section{margin:2rem 0}figure{display:inline-block;margin:8px}img{width:384px;image-rendering:pixelated}figcaption{max-width:384px}"
    labeled = [f"<!doctype html><meta charset='utf-8'><title>LC-03 comparisons</title><style>{style}</style><h1>LC-03 comparisons</h1><p>Developed input, PicEdit, matched Lightcraft, identical values, difference ×8, and Lightcraft alpha composites over linear 0/1. Unmatched pairs cannot prove a quality gain.</p>"]
    blind = [f"<!doctype html><meta charset='utf-8'><title>LC-03 blind pairs</title><style>{style}</style><h1>LC-03 blind pairs</h1><p>Record preference and defects before opening blind-key.json. These image pairs alone do not constitute completed visual approval.</p>"]
    key = []
    (output / "blind").mkdir()
    for number, record in enumerate(records, 1):
        directory = Path("quality") / record["directory"]
        # Native metadata cannot turn report generation into an arbitrary copy.
        if directory.is_absolute() or ".." in directory.parts:
            raise ValueError("Invalid quality image directory")
        title = html.escape(f"{record['fixture']} · {record['direction']} · matched={record['matched']}")
        labeled.append(f"<section><h2>{title}</h2>")
        for filename, label in (("input.png", "Input"), ("picedit.png", "PicEdit"), ("lightcraft.png", "Lightcraft matched"),
                                ("same-values.png", "Lightcraft same values"), ("difference.png", "Difference ×8"),
                                ("dark.png", "Dark composite"), ("light.png", "Light composite")):
            path = directory / filename
            if not (output / path).is_file():
                raise ValueError(f"Missing image artifact: {path}")
            labeled.append(f"<figure><img src='{html.escape(path.as_posix(), quote=True)}'><figcaption>{label}</figcaption></figure>")
        labeled.append("</section>")
        pair = [("picedit.png", "picedit"), ("lightcraft.png", "lightcraft")]
        if hashlib.sha256(f"lc03-blind-v1:{record['fixture']}:{record['direction']}".encode()).digest()[0] % 2:
            pair.reverse()
        blind.append(f"<section><h2>Pair {number:03d}</h2>")
        entry = {"pair": number, "fixture": record["fixture"], "direction": record["direction"], "matched": record["matched"]}
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
        raise ValueError("LC-03 has no registered real-photo ROIs; --real-manifest remains an LC-01 diagnostic option")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    protocol_source = SOURCE / "lc03-manifest.json"
    manifest = json.loads(protocol_source.read_text())
    frozen = output / "lc03-manifest.json"
    frozen.write_bytes(protocol_source.read_bytes())
    sources = list((ROOT / "Sources").rglob("*.swift"))
    sources += [ROOT / "Package.swift", ROOT / "Package.resolved", SOURCE / "run.py", Path(__file__),
                ROOT / "scripts/evaluate-lightcraft.sh", ROOT / "scripts/build-developer-tool.sh",
                SOURCE / "THIRD-PARTY-NOTICES.txt"]
    sources += [p for p in (SOURCE / "lc03-reference-oracle").rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    sources += [p for p in (SOURCE / "licenses").rglob("*") if p.is_file()]
    hashes = {str(p.relative_to(ROOT)): common.digest(p) for p in sorted(set(sources)) if p.is_file()}
    hardware = common.command(["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini"])
    hardware = "\n".join(line for line in hardware.splitlines() if not any(k in line for k in ("Serial Number", "Hardware UUID", "Provisioning UDID")))
    metadata = {"schema_version": 1, "candidate": "LC-03", "base_commit": common.command(["git", "rev-parse", "HEAD"]),
                "source_sha256": hashes, "binary_sha256": common.digest(args.binary),
                "manifest_sha256": common.digest(frozen), "toolchain": common.command(["xcrun", "swift", "--version"]),
                "os": common.command(["sw_vers"]), "hardware": hardware, "architecture": platform.machine(),
                "timing_concurrency": 1, "configuration": "release, existing editing harness",
                "timing_order": "Per size, five paired repetitions; odd repetitions PicEdit then Lightcraft, even repetitions Lightcraft then PicEdit",
                "backend": "PicEdit: Core Image automatic; candidate: bounded CPU reference; no accelerated-path claim",
                "sizes": manifest["performanceBudgets"]["sizes"], "repetitions": 5,
                "warm_samples_per_process": 5, "warmups_per_process": 1, "real_inputs": "none"}
    common.write_json(output / "environment.json", metadata)
    invocations = []
    calibration = output / "tuning/calibration.json"
    calibration_hash = None

    def unchanged():
        if common.digest(protocol_source) != metadata["manifest_sha256"] or common.digest(frozen) != metadata["manifest_sha256"]:
            raise ValueError("LC-03 protocol changed during evaluation")
        if common.digest(args.binary) != metadata["binary_sha256"] or any(common.digest(ROOT / p) != h for p, h in hashes.items()):
            raise ValueError("LC-03 binary or sources changed during evaluation")
        if calibration_hash is not None and common.digest(calibration) != calibration_hash:
            raise ValueError("Calibration changed after tuning was frozen")

    def invoke(mode, name, width=512, height=320, adapter=None):
        unchanged()
        cmd = [str(args.binary.resolve()), "--scenario", "evaluation", "--evaluation-mode", "tone-" + mode,
               "--manifest", str(frozen), "--output", str(output / name), "--width", str(width),
               "--height", str(height), "--iterations", "5"]
        if mode != "tune":
            cmd += ["--calibration", str(calibration)]
        if adapter:
            cmd += ["--adapter", adapter]
        invocations.append(cmd)
        common.write_json(output / "commands.json", invocations)
        print(f"LC-03: {name}", flush=True)
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
    for width, height in manifest["performanceBudgets"]["sizes"]:
        adapters = {"picedit": [], "lightcraft": []}
        # Pair the processes and alternate the first adapter without concurrent
        # workloads, reducing order/thermal drift without adding samples.
        for number in range(1, 6):
            order = ("picedit", "lightcraft") if number % 2 else ("lightcraft", "picedit")
            for adapter in order:
                name = f"timing-{width}-{adapter}-{number}"
                invoke("timing", name, width, height, adapter)
                run = json.loads((output / name / "timing.json").read_text())
                if run.get("adapter") != adapter:
                    raise ValueError("Timing adapter metadata mismatch")
                adapters[adapter].append(run)
        performance.append(performance_comparison(width, height, adapters["picedit"], adapters["lightcraft"], manifest))
    invoke("scale", "scale", *manifest["performanceBudgets"]["sizes"][-1])
    unchanged()
    decision = decide(quality, manifest, performance)
    summary = {"schema_version": 1, "candidate": "LC-03", **decision, "timings": performance,
               "manifest_sha256": metadata["manifest_sha256"], "calibration_sha256": calibration_hash,
               "quality": "quality/quality.json", "scale": "scale/scale.json", "production_changed": False}
    common.write_json(output / "summary.json", summary)
    print(f"LC-03 complete ({decision['decision']}): {output / 'summary.json'}", flush=True)

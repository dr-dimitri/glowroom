#!/usr/bin/env python3
"""Independent #174 protocol. The actual production USM is measured natively."""
import argparse
import hashlib
import html
import json
import math
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
VARIANTS = ("multiscale", "diffusion")
PROTOCOL_SHA256 = "acb592139b11cf6c780ed4216e67a55a49618af11be4b0ecc65dd6dae4546bb3"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def valid_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def matched(target, value, manifest):
    spec = manifest["matching"]
    return (finite(target) and finite(value) and target >= spec["minimumEffect"] and value > 0
            and abs(value - target) <= max(spec["absoluteTolerance"], spec["relativeTolerance"] * target))


def validate_protocol(manifest):
    expected = [("fine-50", 50, 1, 25, 0), ("fine-100", 100, 1, 25, 0),
                ("wide-100", 100, 2, 25, 0), ("masked-100", 100, 2, 25, 40)]
    actual = [(c.get("id"), c.get("amount"), c.get("radius"), c.get("detail"), c.get("masking"))
              for c in manifest.get("cases", [])]
    canonical = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()
    if manifest.get("protocolID") != "DT174-sharpen-v1" or actual != expected or canonical != PROTOCOL_SHA256:
        raise ValueError("Unsupported DT174 protocol/case matrix; no implicit refit or forced unwrap")


def validate(calibration, quality, manifest, manifest_hash=None, calibration_hash=None):
    validate_protocol(manifest)
    if manifest_hash is not None and (calibration.get("manifestSHA256") != manifest_hash or quality.get("manifest_sha256") != manifest_hash):
        raise ValueError("Manifest provenance mismatch")
    if calibration_hash is not None and quality.get("calibration_sha256") != calibration_hash:
        raise ValueError("Frozen calibration provenance mismatch")
    cases = {c["id"] for c in manifest["cases"]}
    expected_tuning = {(v, c) for v in VARIANTS for c in cases}
    keys = [(r["variant"], r["caseID"]) for r in calibration["records"]]
    if len(keys) != len(set(keys)) or set(keys) != expected_tuning:
        raise ValueError("Incomplete or duplicate calibration")
    tuning = dict(zip(keys, calibration["records"]))
    for row in calibration["records"]:
        if (not valid_hash(row.get("inputSHA256")) or not finite(row.get("parameter"))
                or not 0 <= row["parameter"] <= 6 or not finite(row.get("target")) or not finite(row.get("measured"))):
            raise ValueError("Invalid frozen tuning evidence")
    expected = {(v, c, s) for v in VARIANTS for c in cases for s in manifest["scenes"]}
    keys = [(r["variant"], r["case"], r["scene"]) for r in quality["records"]]
    if len(keys) != len(set(keys)) or any(k not in expected for k in keys):
        raise ValueError("Duplicate or unknown quality row")
    for row in quality["records"]:
        frozen = tuning[row["variant"], row["case"]]
        if (row.get("parameter") != frozen["parameter"] or row.get("tuning_target") != frozen["target"]
                or row.get("tuning_measured") != frozen["measured"] or not valid_hash(row.get("input_sha256"))
                or not valid_hash(row.get("truth_sha256")) or not valid_hash(row.get("output_sha256"))
                or row["input_sha256"] == frozen["inputSHA256"]):
            raise ValueError("Acceptance refit or incomplete independent-input provenance")
        for name in ("baseline_metrics", "candidate_metrics", "unchanged_metrics"):
            metrics = row.get(name)
            required = {"truth_rmse", "detail_contrast", "noise_std", "alpha_error", "hidden_rgb", "visible_samples"}
            if row["scene"] in manifest["primaryScenes"]:
                required |= {"edge_slope", "overshoot", "undershoot", "halo_total", "halo_width_pixels", "edge_rows"}
            if (not isinstance(metrics, dict) or not required <= metrics.keys()
                    or any(not finite(x) or x < 0 for x in metrics.values()) or metrics["visible_samples"] <= 0):
                raise ValueError("Missing/nonfinite/negative measurement or empty support")
            if row["scene"] in manifest["primaryScenes"]:
                if (metrics["edge_rows"] <= 0 or abs(metrics["halo_total"] - metrics["overshoot"] - metrics["undershoot"]) > 1e-10):
                    raise ValueError("Invalid halo/edge support measurement")
    return tuning, expected


def performance_summary(rows, variant, manifest):
    spec = manifest["performance"]
    result = []
    for width, height in spec["sizes"]:
        groups = {adapter: [r for r in rows if r.get("adapter") == adapter and r.get("width") == width and r.get("height") == height]
                  for adapter in ("glowroom", variant)}
        item = {"size": [width, height], "status": "blocked", "reason": "Complete independent process matrix required"}
        if all(len(group) == spec["processes"] for group in groups.values()):
            hashes = {row.get("input_sha256") for group in groups.values() for row in group}
            if len(hashes) != 1 or not all(valid_hash(value) for value in hashes):
                raise ValueError("Timing adapters did not receive identical frozen pixels")
            stats = {}
            for adapter, group in groups.items():
                cold, warm, rss, slopes = [], [], [], []
                if len({row.get("process_index") for row in group}) != spec["processes"]:
                    raise ValueError("Missing/duplicate independent timing process IDs")
                for row in group:
                    phases = {phase: [s for s in row["samples"] if s.get("phase") == phase]
                              for phase in ("process-cold", "warmup", "warm")}
                    if len(phases["process-cold"]) != 1 or len(phases["warmup"]) != 1 or len(phases["warm"]) != spec["warmSamples"]:
                        raise ValueError("Incomplete cold/warm timing samples")
                    samples = phases["process-cold"] + phases["warm"]
                    if any(not finite(s.get("ms")) or s["ms"] <= 0 or not finite(s.get("edge_slope")) or s["edge_slope"] <= 0
                           or not finite(s.get("peak_rss_bytes")) or s["peak_rss_bytes"] <= 0 or not valid_hash(s.get("output_sha256")) for s in samples):
                        raise ValueError("Invalid timing/strength/RSS measurement")
                    cold.append(phases["process-cold"][0]["ms"])
                    warm.extend(s["ms"] for s in phases["warm"])
                    rss.append(max(s["peak_rss_bytes"] for s in samples))
                    slopes.extend(s["edge_slope"] for s in samples)
                stats[adapter] = {"cold_median_ms": statistics.median(cold), "warm_median_ms": statistics.median(warm),
                                  "peak_rss_median_bytes": statistics.median(rss), "edge_slope_mean": statistics.mean(slopes),
                                  "cold_samples": cold, "warm_min_max_ms": [min(warm), max(warm)], "peak_rss_samples": rss}
            before, after = stats["glowroom"], stats[variant]
            equal = matched(before["edge_slope_mean"], after["edge_slope_mean"], manifest)
            ratios = {key: after[key] / before[key] for key in ("cold_median_ms", "warm_median_ms", "peak_rss_median_bytes")}
            budgets = dict(zip(ratios, (spec["maximumColdLatencyRatio"], spec["maximumWarmLatencyRatio"], spec["maximumPeakRSSRatio"])))
            failures = [key for key, ratio in ratios.items() if ratio > budgets[key]] if equal else []
            item.update(status="fail" if failures else "pass" if equal else "blocked", matched=equal,
                        failures=failures, ratios=ratios, samples=stats,
                        reason="Equal-effect isolated-stage costs, including conversions; no RAW/UI/end-to-end production claim")
        result.append(item)
    return result


def scale_summary(scale, variant, manifest):
    if scale is None:
        return {"status": "blocked", "reason": "Native/preview matrix not measured"}
    expected = {tuple(size) for size in manifest["scale"]["previewSizes"]}
    rows = [r for r in scale.get("records", []) if r.get("adapter") == variant]
    keys = [tuple(r.get("preview_size", [])) for r in rows]
    if len(keys) != len(set(keys)) or any(k not in expected for k in keys):
        raise ValueError("Unknown or duplicate scale row")
    if set(keys) != expected:
        return {"status": "blocked", "reason": "Incomplete native/preview matrix"}
    if any(r.get("native_size") != manifest["scale"]["nativeSize"] or not valid_hash(r.get("native_input_sha256"))
           or not valid_hash(r.get("preview_input_sha256")) for r in rows):
        raise ValueError("Scale geometry/provenance mismatch")
    if any(not finite(r.get("scale_rgb_rmse")) or r["scale_rgb_rmse"] < 0 for r in rows):
        return {"status": "blocked", "reason": "Whole-image scale RGB RMSE not measured"}
    failed = [r["preview_size"] for r in rows if r["scale_rgb_rmse"] > manifest["scale"]["maximumRMSE"]]
    return {"status": "fail" if failed else "pass", "failures": failed,
            "records": [{"preview_size": r["preview_size"], "rgb_rmse": r["scale_rgb_rmse"]} for r in rows]}

def decide(calibration, quality, manifest, performance=(), scale=None):
    _, expected = validate(calibration, quality, manifest)
    result = []
    for variant in VARIANTS:
        rows = [r for r in quality["records"] if r["variant"] == variant]
        keys = {(r["variant"], r["case"], r["scene"]) for r in rows}
        complete = keys == {k for k in expected if k[0] == variant}
        failures, missing = [], list(manifest["requiredEvidence"])
        if not complete:
            missing.append("Complete acceptance matrix")
        for row in rows:
            m = row["candidate_metrics"]
            if row.get("finite") is not True or row.get("zero_identity") is not True:
                failures.append(f"{row['case']}/{row['scene']}: finite/zero identity contract")
            if m["alpha_error"] > manifest["critical"]["maximumAlphaError"] or m["hidden_rgb"] > manifest["critical"]["maximumHiddenRGB"]:
                failures.append(f"{row['case']}/{row['scene']}: alpha/hidden RGB contract")
        primary = [r for r in rows if r["scene"] in manifest["primaryScenes"]]
        matching = {r["case"] + "/" + r["scene"]: matched(r["tuning_target"], r["tuning_measured"], manifest)
                    and matched(r["baseline_metrics"]["edge_slope"], r["candidate_metrics"]["edge_slope"], manifest)
                    for r in primary}
        primary_complete = len(primary) == len(manifest["cases"]) * len(manifest["primaryScenes"])
        all_matched = primary_complete and all(matching.values())
        if not all_matched:
            missing.append("Complete equally steep acceptance problem edges with frozen tuning")
        halo = {}
        # A different unmatched edge cannot erase a measured, equally steep
        # per-case veto. Aggregate benefit still requires the complete matrix.
        spec = manifest["primary"]
        for row in primary:
            if not matching[row["case"] + "/" + row["scene"]]:
                continue
            for metric, guard in (("halo_total", spec["maximumAbsoluteHaloRegression"]),
                                  ("halo_width_pixels", spec["maximumHaloWidthRegressionPixels"])):
                if row["candidate_metrics"][metric] - row["baseline_metrics"][metric] > guard:
                    failures.append(f"{row['case']}/{row['scene']}: matched per-case {metric} regression")
        fully_matched_cases = {c["id"] for c in manifest["cases"] if all(
            matching.get(c["id"] + "/" + scene) is True for scene in manifest["primaryScenes"])}
        if complete:
            limits = manifest["critical"]
            for row in rows:
                if row["case"] not in fully_matched_cases:
                    continue
                b, a = row["baseline_metrics"], row["candidate_metrics"]
                label = f"{row['case']}/{row['scene']}"
                if row["scene"] in ("fine-texture", "line-pairs") and a["detail_contrast"] < b["detail_contrast"] * (1 - limits["maximumDetailContrastRelativeLoss"]):
                    failures.append(label + ": matched detail contrast loss")
                if row["scene"] == "noisy-flat" and a["noise_std"] > b["noise_std"] * (1 + limits["maximumNoiseStdRelativeIncrease"]):
                    failures.append(label + ": matched noise std increase")
                if a["truth_rmse"] - b["truth_rmse"] > limits["maximumTruthRMSEIncrease"]:
                    failures.append(label + ": matched truth RMSE increase")
        # Relative quality and cost verdicts are meaningful only at equal effect.
        if primary_complete and all_matched:
            spec = manifest["primary"]
            for metric, floor, regression in (("halo_total", spec["overshootFloor"], spec["maximumAbsoluteHaloRegression"]),
                                               ("halo_width_pixels", spec["haloWidthFloorPixels"], spec["maximumHaloWidthRegressionPixels"])):
                informative = [r for r in primary if r["baseline_metrics"][metric] > floor]
                if not informative:
                    missing.append(f"Informative {metric}")
                    halo[metric] = {"status": "blocked", "informative_rows": 0}
                    continue
                before = statistics.mean(r["baseline_metrics"][metric] for r in informative)
                after = statistics.mean(r["candidate_metrics"][metric] for r in informative)
                improvement = (before - after) / before
                bad = [r["case"] + "/" + r["scene"] for r in primary
                       if r["candidate_metrics"][metric] - r["baseline_metrics"][metric] > regression]
                okay = improvement >= spec["minimumRelativeHaloImprovement"] and not bad
                halo[metric] = {"status": "pass" if okay else "fail", "baseline_mean": before, "candidate_mean": after,
                                "relative_improvement": improvement, "informative_rows": len(informative), "regressions": bad}
                if not okay:
                    failures.append(f"{metric}: no repeatable >=10% benefit or per-case regression")
        diagnostics = performance_summary(performance, variant, manifest)
        for item in diagnostics:
            if item["status"] == "fail":
                failures.append(f"{item['size']}: equal-effect isolated-stage performance budget")
        scaling = scale_summary(scale, variant, manifest)
        if scaling["status"] == "fail":
            failures.append("Native/preview scale RGB RMSE budget")
        result.append({"candidate": variant, "status": "no-go" if failures else "blocked", "failures": failures,
                       "missing_evidence": missing, "matching": matching, "primary": halo,
                       "performance_diagnostics": diagnostics, "scale_diagnostics": scaling,
                       "production_changed": False,
                       "scope": "CPU research adapter cannot itself fulfill real/visual/accelerated/production gates"})
    return result


def gallery(output, quality):
    labeled = ["<!doctype html><meta charset='utf-8'><title>DT174 labeled pairs</title><style>img{width:256px}section{margin-bottom:2em}body{font-family:sans-serif}</style><h1>DT174 — synthetic diagnostic pairs</h1><p>Generated pairs do not constitute independent visual acceptance.</p>"]
    blind = ["<!doctype html><meta charset='utf-8'><title>DT174 blind pairs</title><style>img{width:256px}body{font-family:sans-serif}</style><h1>DT174 blind pairs</h1><p>Record visual judgements before opening blind-key.json.</p>"]
    key, rng = [], random.Random(174)
    neutral = output / "blind-assets"
    neutral.mkdir()
    for index, row in enumerate(quality["records"]):
        directory = row["directory"]
        labeled.append("<section><h2>" + html.escape(directory) + "</h2>")
        for name in ("input", "truth", "glowroom", "candidate", "same-values", "difference", "dark", "light"):
            labeled.append(f'<figure style="display:inline-block"><figcaption>{name}</figcaption><img src="quality/{html.escape(directory)}/{name}.png"></figure>')
        labeled.append("</section>")
        order = ["glowroom", "candidate"]; rng.shuffle(order)
        blind.append(f"<section><h2>Pair {index + 1}</h2>")
        for letter, name in zip(("A", "B"), order):
            path = f"{index + 1}-{letter}.png"
            shutil.copyfile(output / "quality" / directory / f"{name}.png", neutral / path)
            blind.append(f'<figure style="display:inline-block"><figcaption>{letter}</figcaption><img src="blind-assets/{path}"></figure>')
        blind.append("</section>")
        key.append({"pair": index + 1, "directory": directory, "A": order[0], "B": order[1]})
    (output / "labeled.html").write_text("\n".join(labeled))
    (output / "blind.html").write_text("\n".join(blind))
    write(output / "blind-key.json", key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--photo", action="append", type=Path, default=[], help="Explicit local developed PNG/TIFF/JPEG; private diagnostics only")
    parser.add_argument("--timing", action="store_true", help="Complete serial timing matrix; run without competing builds/tests")
    parser.add_argument("--scale", action="store_true", help="Native 4096x2731 and 512/2400 previews; CPU reference can be slow")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error("Choose a new external output directory; repository outputs are forbidden")
    binary = args.binary.resolve(strict=True)
    output.mkdir(parents=True)
    manifest_path = output / "manifest.json"
    shutil.copyfile(HERE / "manifest.json", manifest_path)
    manifest = json.loads(manifest_path.read_text())
    validate_protocol(manifest)
    frozen = {str(p): sha(p) for folder in (ROOT / "Sources", ROOT / "scripts", HERE) for p in folder.rglob("*")
              if p.is_file() and p.suffix in (".swift", ".py", ".json", ".sh")}
    frozen[str(binary)] = sha(binary)
    frozen[str(manifest_path)] = sha(manifest_path)
    write(output / "environment.json", {"platform": platform.platform(), "python": platform.python_version(), "frozen_inputs": frozen,
                                       "backend": "automatic Core Image baseline vs bounded CPU references; physical GPU not proven",
                                       "protocol": manifest["protocolID"], "concurrency": "serial processes; no competing benchmark/build permitted"})
    commands = []

    def check():
        for path, digest in frozen.items():
            if sha(path) != digest:
                raise ValueError("Frozen input changed: " + path)

    def invoke(mode, destination, *extra):
        check()
        command = [str(binary), "--scenario", "evaluation", "--evaluation-mode", "sharpen-" + mode,
                   "--manifest", str(manifest_path), "--output", str(output / destination), "--backend", "default", "--workers", "1", *extra]
        if mode != "tune":
            command += ["--calibration", str(output / "tuning" / "calibration.json")]
        commands.append(command); write(output / "commands.json", commands)
        subprocess.run(command, cwd=ROOT, check=True)
        check()

    invoke("tune", "tuning")
    calibration_path = output / "tuning" / "calibration.json"
    frozen[str(calibration_path)] = sha(calibration_path)
    write(output / "frozen-calibration.json", {"sha256": sha(calibration_path), "source": "tuning-only; acceptance never refit"})
    invoke("quality", "quality")
    calibration = json.loads(calibration_path.read_text())
    quality = json.loads((output / "quality" / "quality.json").read_text())
    validate(calibration, quality, manifest, sha(manifest_path), sha(calibration_path))
    gallery(output, quality)
    photos = []
    for index, path in enumerate(args.photo):
        source = path.resolve(strict=True)
        if source.suffix.lower() not in (".png", ".tif", ".tiff", ".jpg", ".jpeg"):
            raise ValueError("--photo requires a developed PNG/TIFF/JPEG; RAWs must be explicitly developed separately")
        destination = output / "private-inputs" / (str(index) + source.suffix.lower())
        destination.parent.mkdir(exist_ok=True)
        digest = sha(source)
        shutil.copyfile(source, destination)
        if sha(source) != digest or sha(destination) != digest:
            raise ValueError("Private input changed during snapshot")
        frozen[str(destination)] = digest
        directory = f"private-photo-{index}"
        invoke("photo", directory, "--input", str(destination))
        photos.append({"source_sha256": digest, "directory": directory,
                       "status": "private diagnostic-only; no qualified scene/ground truth/equal effect/visual approval"})
    performance = []
    if args.timing:
        spec = manifest["performance"]
        for width, height in spec["sizes"]:
            for adapter in ("glowroom", *VARIANTS):
                for process in range(spec["processes"]):
                    directory = f"timing-{width}-{height}-{adapter}-{process}"
                    invoke("timing", directory, "--width", str(width), "--height", str(height), "--adapter", adapter,
                           "--iterations", str(spec["warmSamples"]))
                    record = json.loads((output / directory / "timing.json").read_text())
                    record["process_index"] = process
                    performance.append(record)
    scale = None
    if args.scale:
        width, height = manifest["scale"]["nativeSize"]
        invoke("scale", "scale", "--width", str(width), "--height", str(height))
        scale = json.loads((output / "scale" / "scale.json").read_text())
    check()
    write(output / "summary.json", {"protocol": manifest["protocolID"], "decisions": decide(calibration, quality, manifest, performance, scale),
                                   "timing_complete": args.timing, "scale_complete": args.scale, "production_changed": False, "private_photos": photos,
                                   "manifest_sha256": sha(manifest_path), "calibration_sha256": sha(calibration_path)})
    print(output / "summary.json")


if __name__ == "__main__":
    main()

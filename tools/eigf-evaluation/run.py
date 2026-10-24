#!/usr/bin/env python3
"""Frozen #173 protocol. Reuse LC-03 reductions and decision gates, not its candidate."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/lightcraft-evaluation"))
import lc03


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False, sort_keys=True) + "\n")


def decide(quality, manifest, calibration, performance=()):
    rows = quality["records"]
    expected = {(basis, scene, d["id"]) for basis in ("simple", "eigf")
                for scene in manifest["sceneClasses"] for d in manifest["comparison"]["directions"]}
    seen = [(r["basis"], r["scene_class"], r["direction"]) for r in rows]
    if len(seen) != len(set(seen)) or any(item not in expected for item in seen):
        raise ValueError("Duplicate or unknown EIGF quality record")
    fits = {(r["basis"], r["fit"]["sceneClass"], r["fit"]["directionID"]): r["fit"] for r in calibration["records"]}
    if len(fits) != len(calibration["records"]) or set(fits) != expected:
        raise ValueError("Incomplete or duplicate frozen EIGF calibration")
    for row in rows:
        fit = fits[(row["basis"], row["scene_class"], row["direction"])]
        if fit["matched"] is not lc03.effect_matches(fit["target"], fit["measured"], manifest["comparison"]):
            raise ValueError("Frozen EIGF calibration matching is inconsistent")
        if row["parameter"] != fit["parameter"]:
            raise ValueError("Acceptance changed a frozen EIGF parameter")
        expected_match = fit["matched"] and lc03.effect_matches(row["target"], row["measured"], manifest["comparison"])
        if row["matched"] is not expected_match:
            raise ValueError("EIGF native matching flag conflicts with frozen signed effect rule")
        metrics = row["comparison_metrics"]
        required = {"alpha_error", "hue_deviation_degrees", "target_gamut_fraction_increase",
                    "target_clipping_fraction_increase", "target_new_gamut_fraction", "target_new_clipping_fraction"}
        if row["scene_class"] == "noise":
            required.add("noise_gain_ratio")
        if not required.issubset(metrics) or any(not lc03.finite(v) or v < 0 for v in metrics.values()):
            raise ValueError("Missing, nonfinite or invalid critical EIGF metrics")
        failures = []
        if expected_match:
            limits = manifest["comparison"]["criticalLimits"]
            for key, limit in (("alpha_error", limits["alphaError"]), ("hue_deviation_degrees", limits["hueDeviationDegrees"])):
                if metrics[key] > limit:
                    failures.append(key)
            if row["scene_class"] != "hdr":
                for key in ("target_gamut_fraction_increase", "target_new_gamut_fraction"):
                    if metrics[key] > limits["gamutFractionIncrease"]:
                        failures.append(key)
                for key in ("target_clipping_fraction_increase", "target_new_clipping_fraction"):
                    if metrics[key] > limits["clippingFractionIncrease"]:
                        failures.append(key)
            if row["scene_class"] == "hard-edge":
                for key, limit in (("halo_overshoot", limits["haloOvershoot"]), ("halo_undershoot", limits["haloUndershoot"])):
                    value = row["candidate_metrics"].get(key)
                    if not lc03.finite(value) or value < 0:
                        raise ValueError("Missing finite EIGF halo support")
                    if value > limit:
                        failures.append(key)
            if metrics.get("noise_gain_ratio", 1) > manifest["maximumNoiseGainRatio"]:
                failures.append("noise_gain_ratio")
        if sorted(row["critical_failures"]) != sorted(failures):
            raise ValueError("Native EIGF critical-failure flags disagree with numeric gates")
    comparison = {**manifest["comparison"],
                  "requiredMissingUntilMeasured": list(manifest["requiredMissingUntilMeasured"]),
                  "performanceBudgets": manifest["performanceBudgets"]}
    decisions = {}
    for basis in ("simple", "eigf"):
        selected = {"records": [r for r in rows if r["basis"] == basis]}
        timing = [p for p in performance if p["basis"] == basis]
        decisions[basis] = lc03.decide(selected, comparison, timing)
        decisions[basis]["scope"] = "Independent EIGF hypothesis, V2 Float contract; isolated synthetic CPU reference"
        # Alpha preservation is an unconditional transport contract; an
        # unreachable tone target cannot hide damage to coverage.
        alpha_failures = [f"{r['scene_class']}/{r['direction']}: alpha transport contract"
                          for r in selected["records"] if r["comparison_metrics"]["alpha_error"] > comparison["criticalLimits"]["alphaError"]]
        if alpha_failures:
            decisions[basis]["decision"] = "no-go"
            decisions[basis]["critical_failures"].extend(alpha_failures)
    return {"protocol": manifest["protocolID"], "candidates": decisions,
            "production": "unchanged; no synthetic run can grant integration",
            "expected_quality_records": len(expected), "quality_records": len(rows)}


def views(output, rows):
    labeled = ["<!doctype html><meta charset='utf-8'><title>EIGF comparison</title><h1>EIGF comparison</h1><p>Float metrics gate the result. PNGs are SDR diagnostics. No visual approval has been recorded.</p>"]
    blind = ["<!doctype html><meta charset='utf-8'><title>EIGF blind pairs</title><h1>EIGF blind pairs</h1><p>Record decisions before opening blind-key.json. Page generation is not visual acceptance.</p>"]
    key = []
    (output / "blind").mkdir()
    for i, row in enumerate(rows, 1):
        folder = Path("quality") / row["directory"]
        if folder.is_absolute() or ".." in folder.parts:
            raise ValueError("Unsafe native image path")
        label = html.escape(f"{row['scene_class']} / {row['direction']} / {row['basis']}; matched={row['matched']}")
        labeled.append(f"<h2>{label}</h2>")
        for name in ("input", "glowroom", "candidate", "same-values", "difference", "dark", "light"):
            file = folder / f"{name}.png"
            if not (output / file).is_file():
                raise ValueError("Missing comparison PNG")
            labeled.append(f"<figure style='display:inline-block'><img width='256' src='{html.escape(str(file), quote=True)}'><figcaption>{name}</figcaption></figure>")
        order = ["glowroom", "candidate"]
        if hashlib.sha256(label.encode()).digest()[0] % 2:
            order.reverse()
        blind.append(f"<h2>Pair {i}</h2>")
        for letter, name in zip(("A", "B"), order):
            path = Path("blind") / f"{i:03d}-{letter}.png"
            shutil.copyfile(output / folder / f"{name}.png", output / path)
            blind.append(f"<figure style='display:inline-block'><img width='384' src='{path}'><figcaption>{letter}</figcaption></figure>")
        key.append({"pair": i, "basis": row["basis"], "scene": row["scene_class"], "direction": row["direction"], "A": order[0], "B": order[1]})
    (output / "labeled.html").write_text("\n".join(labeled))
    (output / "blind.html").write_text("\n".join(blind))
    write(output / "blind-key.json", key)


def run(args):
    output = args.output.resolve()
    if output.exists():
        raise ValueError("Refusing to overwrite EIGF result directory")
    output.mkdir(parents=True)
    manifest_path = Path(__file__).with_name("manifest.json")
    frozen_manifest = output / "manifest.json"
    shutil.copyfile(manifest_path, frozen_manifest)
    manifest = json.loads(frozen_manifest.read_text())
    binary = args.binary.resolve(strict=True)
    sources = sorted(set(ROOT.glob("Sources/**/*.swift")) | set(ROOT.glob("Tests/**/*.swift"))
                     | set((ROOT / "tools/eigf-evaluation").glob("*.py"))
                     | {manifest_path, ROOT / "Package.swift", ROOT / "Package.resolved",
                        ROOT / "tools/lightcraft-evaluation/lc03.py", ROOT / "tools/lightcraft-evaluation/run.py",
                        ROOT / "scripts/build-developer-tool.sh"})
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in sources}
    binary_hash = digest(binary)
    environment = {"platform": platform.platform(), "machine": platform.machine(), "python": platform.python_version(),
                   "manifest_sha256": digest(frozen_manifest), "source_hashes": hashes,
                   "binary_sha256": binary_hash, "binary": str(binary),
                   "method": "separate tuning/acceptance processes; candidate benchmarks serial; sources frozen before tuning",
                   "scope": "already-developed identical Float pixels; private JPEG fixtures are optional and unused; local RAWs exist but are not qualified acceptance scenes"}
    write(output / "environment.json", environment)
    commands = []

    def unchanged():
        if digest(binary) != binary_hash or any(digest(ROOT / name) != value for name, value in hashes.items()) or digest(frozen_manifest) != environment["manifest_sha256"]:
            raise ValueError("Frozen EIGF source/binary/protocol changed")

    def native(mode, name, adapter="glowroom", size=(512, 320), calibration=None):
        unchanged()
        command = [str(binary), "--scenario", "evaluation", "--evaluation-mode", f"eigf-{mode}",
                   "--manifest", str(frozen_manifest), "--output", str(output / name), "--adapter", adapter,
                   "--backend", "default", "--workers", "1", "--iterations", "5",
                   "--width", str(size[0]), "--height", str(size[1])]
        if calibration:
            command += ["--calibration", str(calibration)]
        commands.append(command)
        write(output / "commands.json", commands)
        subprocess.run(command, cwd=ROOT, check=True)
        unchanged()

    native("tune", "tuning")
    calibration = output / "tuning/calibration.json"
    calibration_hash = digest(calibration)
    environment["calibration_sha256"] = calibration_hash
    write(output / "environment.json", environment)
    native("quality", "quality", calibration=calibration)
    if digest(calibration) != calibration_hash:
        raise ValueError("Calibration changed after freeze")
    quality = json.loads((output / "quality/quality.json").read_text())
    if quality["manifest_sha256"] != environment["manifest_sha256"] or quality["calibration_sha256"] != calibration_hash:
        raise ValueError("Native quality provenance differs from frozen inputs")
    performance = []
    if args.timing:
        for size in manifest["performanceBudgets"]["sizes"]:
            runs = {}
            for adapter in ("glowroom", "simple", "eigf"):
                runs[adapter] = []
                for repeat in range(5):
                    name = f"timing-{size[0]}x{size[1]}-{adapter}-{repeat}"
                    native("timing", name, adapter, size, calibration)
                    runs[adapter].append(json.loads((output / name / "timing.json").read_text()))
            for basis in ("simple", "eigf"):
                item = lc03.performance_comparison(*size, runs["glowroom"], runs[basis],
                    {**manifest["comparison"], "performanceBudgets": manifest["performanceBudgets"]})
                item["basis"] = basis
                item["candidate"] = item.pop("lightcraft")
                item["note"] = "Independent CPU basis versus V2 CI; ratios gate only phases with matched effects, not a GPU speed claim"
                performance.append(item)
    if args.scale:
        native("scale", "scale", size=(2400, 1600), calibration=calibration)
    unchanged()
    views(output, quality["records"])
    summary = decide(quality, manifest, json.loads(calibration.read_text()), performance)
    summary["performance"] = performance
    summary["manifest_sha256"] = environment["manifest_sha256"]
    summary["calibration_sha256"] = calibration_hash
    summary["scale_measured"] = args.scale
    write(output / "summary.json", summary)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--binary", type=Path, required=True, help="Prebuilt editing harness from this source checkout")
    parser.add_argument("--timing", action="store_true", help="Full serial four-size, five-process timing matrix; run without competing builds/tests")
    parser.add_argument("--scale", action="store_true", help="2400x1600 versus downsampled graph diagnostic")
    run(parser.parse_args())

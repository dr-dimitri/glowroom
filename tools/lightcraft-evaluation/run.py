#!/usr/bin/env python3
"""Serial orchestration/reporting for the existing Swift editing harness."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import platform
import statistics
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
SIZES = ((400, 267), (2400, 1600), (4096, 2731), (4608, 3072))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def command(args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def distribution(values):
    if not values or any(not isinstance(x, (int, float)) or not 0 <= x < float("inf") for x in values):
        raise ValueError("Expected finite, nonnegative timing samples")
    ordered = sorted(values)
    result = {"n": len(values), "median_ms": statistics.median(values), "min_ms": ordered[0], "max_ms": ordered[-1]}
    # No invented p95 for the usual 5 cold / 25 warm observations.
    if len(values) >= 30:
        import math
        result.update(p95_ms=ordered[math.ceil(.95 * len(values)) - 1], p95_method="nearest-rank ceil(0.95*n)")
    return result


def timing_summary(runs):
    cold, warm, warmups = [], [], []
    for run in runs:
        phases = {name: [s["total_ms"] for s in run["samples"] if s["phase"] == name]
                  for name in ("process-cold", "warmup", "warm")}
        if len(phases["process-cold"]) != 1 or len(phases["warmup"]) != 1 or len(phases["warm"]) < 5:
            raise ValueError("Incomplete timing run")
        cold += phases["process-cold"]
        warm += phases["warm"]
        warmups += phases["warmup"]
    if len(runs) < 5:
        raise ValueError("At least five separate process runs required")
    if len({run["input_sha256"] for run in runs}) != 1:
        raise ValueError("Timing inputs differ between repetitions")
    return {"process_cold": distribution(cold), "warm": distribution(warm),
            "warmup_excluded": distribution(warmups),
            "peak_rss_bytes": max(run["peak_rss_bytes"] for run in runs),
            "input_sha256": runs[0]["input_sha256"],
            "note": "OS/driver caches not cleared; warm samples nested within five processes; no statistical independence claim"}


def real_inputs(path):
    if path is None:
        return []
    manifest_path = Path(path).resolve()
    manifest = json.loads(manifest_path.read_text())
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError("Real manifest needs a nonempty files list")
    result = []
    for entry in files:
        if not all(isinstance(entry.get(k), str) and entry[k].strip() for k in ("path", "sha256", "license", "source", "scene_class")):
            raise ValueError("Each real fixture needs path, sha256, license, source and scene_class")
        if entry.get("permission_to_use") is not True:
            raise ValueError("Each real fixture must explicitly declare permission_to_use: true")
        file = (manifest_path.parent / entry["path"]).resolve()
        if file.suffix.lower() not in {".png", ".tif", ".tiff", ".jpg", ".jpeg"}:
            raise ValueError("Only already-developed PNG/TIFF/JPEG rasters are accepted, never RAW")
        if digest(file) != entry["sha256"]:
            raise ValueError("Real fixture SHA256 mismatch")
        result.append((file, entry))
    return result


def views(output, records):
    style = "body{font:15px system-ui;margin:2rem;background:#eee;color:#222}section{margin:2rem 0}figure{display:inline-block;margin:8px}img{width:384px;image-rendering:pixelated}figcaption{max-width:384px}"
    labeled = [f"<!doctype html><meta charset='utf-8'><title>LC-01 labeled comparisons</title><style>{style}</style><h1>LC-01 labeled comparisons</h1><p>Input / output / absolute premultiplied RGB difference ×8. Dark/light composites use linear 0/1. Baselines are diagnostic, not candidate wins.</p>"]
    blind = [f"<!doctype html><meta charset='utf-8'><title>LC-01 blind pairs</title><style>{style}</style><h1>LC-01 blind pairs</h1><p>Record preference and defects before opening blind-key.json. Includes controls and baseline effects; these pairs do not constitute a matched candidate evaluation.</p>"]
    key = []
    for number, record in enumerate(records):
        fixture, adapter = record["fixture"], record["adapter"]
        base = f"quality/{fixture}/"
        title = html.escape(f"{fixture} · {adapter} · {record['status']}")
        labeled.append(f"<section><h2>{title}</h2>")
        files = [("input.png", "Input"), (f"{adapter}.png", "Output"),
                 (f"{adapter}-difference.png", "Difference ×8"), (f"{adapter}-dark.png", "Dark composite"), (f"{adapter}-light.png", "Light composite")]
        for file, label in files:
            labeled.append(f"<figure><img src='{html.escape(base + file, quote=True)}'><figcaption>{label}</figcaption></figure>")
        labeled.append("</section>")
        pair = ["input.png", f"{adapter}.png"]
        flip = hashlib.sha256(f"lc01-blind-v1:{fixture}:{adapter}".encode()).digest()[0] % 2
        if flip:
            pair.reverse()
        blind.append(f"<section><h2>Pair {number + 1:03d}</h2>")
        # Opaque image copies also hide the mapping from ordinary browser URLs.
        for label, file in zip(("A", "B"), pair):
            target = f"blind/{number + 1:03d}-{label}.png"
            (output / "blind").mkdir(exist_ok=True)
            shutil.copyfile(output / base / file, output / target)
            blind.append(f"<figure><img src='{target}'><figcaption>{label}</figcaption></figure>")
        blind.append("</section>")
        key.append({"pair": number + 1, "fixture": fixture, "adapter": adapter,
                    "A": "output" if flip else "input", "B": "input" if flip else "output"})
    (output / "labeled.html").write_text("\n".join(labeled))
    (output / "blind.html").write_text("\n".join(blind))
    write_json(output / "blind-key.json", key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--real-manifest", type=Path)
    args = parser.parse_args()
    # Validate personal fixtures before any output or compute. No downloading,
    # publishing, scanning the user's library, or implicit license assumptions.
    real = real_inputs(args.real_manifest)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    private_inputs = []
    for i, (file, provenance) in enumerate(real):
        directory = output / "private-inputs"
        directory.mkdir(exist_ok=True, mode=0o700)
        snapshot = directory / f"{i + 1}{file.suffix.lower()}"
        shutil.copyfile(file, snapshot)
        snapshot.chmod(0o600)
        if digest(snapshot) != provenance["sha256"]:
            raise ValueError("Real fixture changed while freezing its private snapshot")
        private_inputs.append((snapshot, provenance))
    manifest = SOURCE / "measurement-manifest.json"
    registry = SOURCE / "candidate-registry.json"
    frozen_manifest = output / manifest.name
    frozen_registry = output / registry.name
    frozen_manifest.write_bytes(manifest.read_bytes())
    frozen_registry.write_bytes(registry.read_bytes())
    sources = [ROOT / "Package.swift", ROOT / "Package.resolved", Path(__file__), ROOT / "scripts/evaluate-lightcraft.sh"]
    sources += sorted((ROOT / "Sources/PicEdit/DeveloperTools").glob("*Evaluation*.swift"))
    sources += [ROOT / "Sources/PicEdit/DeveloperTools/EditingBenchmark.swift", ROOT / "Sources/PicEdit/Imaging/EditRenderer.swift"]
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sources if p.exists()}
    hardware = command(["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini"])
    hardware = "\n".join(line for line in hardware.splitlines() if not any(k in line for k in ("Serial Number", "Hardware UUID", "Provisioning UDID")))
    metadata = {"schema_version": 1, "base_commit": command(["git", "rev-parse", "HEAD"]),
                "tracked_worktree_diff_sha256": hashlib.sha256(command(["git", "diff", "HEAD", "--", "Sources", "scripts", "tools"]).encode()).hexdigest(),
                "source_sha256": source_hashes, "binary_sha256": digest(args.binary),
                "manifest_sha256": digest(manifest), "registry_sha256": digest(registry),
                "toolchain": command(["xcrun", "swift", "--version"]), "os": command(["sw_vers"]),
                "hardware": hardware, "architecture": platform.machine(),
                "configuration": "release, existing editing harness", "sizes": SIZES,
                "repetitions": 5, "warm_samples_per_process": 5, "warmups_per_process": 1,
                "timing_concurrency": 1, "backend": "Core Image automatic; no forced CPU/GPU comparison",
                "missing_real_classes": ["licensed photographic portraits", "natural fine edges/textures", "high-ISO RAW-developed rasters"],
                "real_inputs": "none" if not real else "explicit local inputs, not publication/acceptance approval"}
    write_json(output / "environment.json", metadata)
    invocations = []

    def invoke(mode, name, width=192, height=128, extra=()):
        cmd = [str(args.binary.resolve()), "--scenario", "evaluation", "--evaluation-mode", mode,
               "--output", str(output / name), "--manifest", str(frozen_manifest), "--registry", str(frozen_registry),
               "--width", str(width), "--height", str(height), "--iterations", "5", *extra]
        invocations.append(cmd)
        write_json(output / "commands.json", invocations)
        print(f"LC-01: {name}", flush=True)
        with (output / f"{name}.log").open("w") as log:
            subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

    invoke("quality", "quality")
    quality = json.loads((output / "quality/quality.json").read_text())
    if quality["manifest_sha256"] != metadata["manifest_sha256"] or quality["control_failures"]:
        raise ValueError("Acceptance controls or frozen manifest failed")
    views(output, quality["records"])
    timings = []
    for width, height in SIZES:
        runs = []
        for run in range(5):
            name = f"timing-{width}-{run + 1}"
            invoke("timing", name, width, height)
            runs.append(json.loads((output / name / "timing.json").read_text()))
        timings.append({"width": width, "height": height, **timing_summary(runs)})
    invoke("scale", "scale", *SIZES[-1])
    for i, (file, provenance) in enumerate(private_inputs):
        invoke("quality", f"private-real-{i + 1}", extra=("--input", str(file)))
        write_json(output / f"private-real-{i + 1}/provenance.json", provenance)
    # Reject a mutable source/manifest during the run, rather than labeling a
    # mixed revision as reproducible evidence.
    if (digest(manifest) != metadata["manifest_sha256"] or digest(frozen_manifest) != metadata["manifest_sha256"] or
            digest(registry) != metadata["registry_sha256"] or digest(frozen_registry) != metadata["registry_sha256"]):
        raise ValueError("Source manifest/registry changed during evaluation")
    if digest(args.binary) != metadata["binary_sha256"]:
        raise ValueError("Harness binary changed during evaluation")
    if any(digest(ROOT / p) != h for p, h in source_hashes.items()):
        raise ValueError("Harness sources changed during evaluation")
    summary = {"schema_version": 1, "controls": "pass", "quality_records": len(quality["records"]),
               "timings": timings, "candidates": quality["candidates"],
               "manifest_sha256": metadata["manifest_sha256"], "performance_claim": "baseline only; no gain claimed",
               "scale_comparison": "scale/scale.json"}
    write_json(output / "summary.json", summary)
    print(f"LC-01 complete: {output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        print(f"LC-01 failed: {error}", file=sys.stderr)
        sys.exit(1)

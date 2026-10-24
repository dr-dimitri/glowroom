#!/usr/bin/env python3
"""Frozen #175 developed-raster experiment; absence of evidence cannot become Go."""
import argparse
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def finite(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def valid_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def components(control):
    return ["luminance", "chroma"] if control == "joint" else [control]


def matches(target, measured, manifest):
    m = manifest["matching"]
    return (finite(target) and finite(measured) and target >= m["minimumTarget"] and measured > 0
            and abs(target-measured) <= max(m["absoluteTolerance"], m["relativeTolerance"] * target))


def validate_manifest(manifest):
    candidate = manifest["candidate"]
    if (manifest["schemaVersion"] != 1 or manifest["protocolID"] != "multiscale-denoise-175-v1"
            or candidate["strides"] != [1,2,4] or candidate["thresholds"] != [.04,.028,.018]
            or candidate["lumaEdge"] != .06 or candidate["chromaEdge"] != .06
            or manifest["matching"] != {"minimumTarget":.0002,"absoluteTolerance":.00001,"relativeTolerance":.05,"coarseSteps":33,"refinementSteps":17}
            or manifest["qualityGates"] != {"minimumMeanImprovement":.1,"floor":.00001,"maximumCaseAbsoluteRegression":.00001,"maximumCaseRelativeRegression":.1,"metrics":["detail_rgb_rmse","edge_gradient_rmse"]}
            or manifest["criticalGates"] != {"luma_drift_mean":.005,"chroma_fringing_rmse":.005,"target_outside_fraction":.02,"target_boundary_fraction":.02,"target_new_outside_fraction":.02}
            or manifest["alphaTolerance"] != .001):
        raise ValueError("Changed candidate or preregistered acceptance gates")


def expected(manifest):
    return {(s, c, v) for s in manifest["scenes"] for c in manifest["controls"] for v in manifest["values"]}


def keyed(rows, manifest):
    keys = [(r["scene"], r["control"], r["value"]) for r in rows]
    if len(set(keys)) != len(keys) or set(keys) != expected(manifest):
        raise ValueError("Incomplete or duplicate #175 measurement matrix")
    return dict(zip(keys, rows))


def validate_calibration(calibration, manifest, quality=None):
    frozen = keyed(calibration["records"], manifest)
    for (_, control, _), row in frozen.items():
        if (not valid_hash(row["inputSHA256"]) or not valid_hash(row["truthSHA256"])
                or any(not finite(row[k]) or not 0 <= row[k] <= 100 for k in ("luminance", "chroma"))
                or set(row["targets"]) != set(components(control)) or set(row["measured"]) != set(components(control))
                or any(not finite(x) for d in (row["targets"], row["measured"]) for x in d.values())
                or row["matched"] is not all(matches(row["targets"][c], row["measured"][c], manifest) for c in components(control))):
            raise ValueError("Invalid #175 frozen calibration")
        if control == "chroma" and row["luminance"] != 0 or control == "luminance" and row["chroma"] != 0:
            raise ValueError("Inactive control changed")
    if quality is not None:
        for key, row in keyed(quality["records"], manifest).items():
            f = frozen[key]
            if (row["luminance"] != f["luminance"] or row["chroma"] != f["chroma"] or row["tuningMatched"] is not f["matched"]
                    or not valid_hash(row["inputSHA256"]) or not valid_hash(row["truthSHA256"]) or not valid_hash(row["outputSHA256"])
                    or row["inputSHA256"] == f["inputSHA256"] or row["truthSHA256"] != f["truthSHA256"]):
                raise ValueError("Acceptance refit or invalid independent-seed provenance")


def quality_decisions(quality, manifest):
    validate_manifest(manifest)
    rows = keyed(quality["records"], manifest)
    zero_keys = [(r["scene"], r["control"]) for r in quality["zero"]]
    if len(set(zero_keys)) != len(zero_keys) or set(zero_keys) != {(s,c) for s in manifest["scenes"] for c in manifest["controls"]}:
        raise ValueError("Incomplete exact-zero matrix")
    contract_failures = []
    for row in quality["zero"]:
        if not valid_hash(row["inputSHA256"]) or not valid_hash(row["outputSHA256"]) or row["identity"] is not (row["inputSHA256"] == row["outputSHA256"]):
            raise ValueError("Invalid zero identity provenance")
        if not row["identity"]:
            contract_failures.append(row["control"])
    for key, row in rows.items():
        control = key[1]
        if set(row["targets"]) != set(components(control)) or set(row["measured"]) != set(components(control)):
            raise ValueError("Missing effect measurements")
        actual_match = all(matches(row["targets"][c], row["measured"][c], manifest) for c in components(control)) and row["tuningMatched"]
        if row["matched"] is not actual_match:
            raise ValueError("Forged matching flag")
        for label in ("baseline", "candidate"):
            metrics = row[label]
            if not metrics or any(not finite(v) for v in metrics.values()):
                raise ValueError("Missing/nonfinite metrics")
            needed = ["detail_rgb_rmse", "edge_gradient_rmse", "noise_sample_count", "noise_visible_weight", "detail_sample_count", "detail_visible_weight", "edge_sample_count", "edge_visible_weight", "alpha_error", "hidden_rgb_error"] + list(manifest["criticalGates"])
            if any(k not in metrics for k in needed):
                raise ValueError("Missing ground-truth metric support")
            for c in components(control):
                prefix = "luma" if c == "luminance" else "chroma"
                before, after = metrics[f"input_noise_{prefix}_rmse"], metrics[f"noise_{prefix}_rmse"]
                reported = row["targets" if label == "baseline" else "measured"][c]
                if before <= 1e-12 or abs(1 - after/before - reported) > 1e-9:
                    raise ValueError("Effect does not derive from ground-truth residuals")
        if row["candidate"]["alpha_error"] > manifest["alphaTolerance"] or row["candidate"]["hidden_rgb_error"] != 0:
            contract_failures.append(control)
    decisions = {}
    gates = manifest["qualityGates"]
    for control in manifest["controls"]:
        subset = [r for (s,c,v),r in rows.items() if c == control]
        primary = [r for r in subset if r["scene"] in manifest["primaryScenes"] and r["value"] in (20,60)]
        missing, failures, means = [], [], {}
        if control in contract_failures:
            failures.append("exact-zero/alpha/hidden-RGB contract")
        if any(not r["matched"] for r in subset):
            missing.append("positive strength matching for every acceptance case")
        support_complete = all(r[label].get(k,0) > 0 for r in primary for label in ("baseline","candidate") for k in ("noise_sample_count","noise_visible_weight","detail_sample_count","detail_visible_weight","edge_sample_count","edge_visible_weight"))
        if not support_complete:
            missing.append("fixed independent mask support")
        for metric in gates["metrics"]:
            informative = [r for r in primary if r["baseline"][metric] >= gates["floor"]]
            if not informative:
                missing.append("informative baseline " + metric)
            elif support_complete and all(r["matched"] for r in primary):
                before = statistics.mean(r["baseline"][metric] for r in primary)
                after = statistics.mean(r["candidate"][metric] for r in primary)
                means[metric] = {"baseline": before, "candidate": after, "improvement": 1-after/before}
                if after > before * (1-gates["minimumMeanImprovement"]):
                    failures.append("primary mean " + metric)
            # A different unmatched case cannot erase a measured regression
            # in an independently matched case with complete fixed support.
            for r in primary:
                case_supported = all(r[label].get(k,0) > 0 for label in ("baseline","candidate") for k in ("noise_sample_count","noise_visible_weight","detail_sample_count","detail_visible_weight","edge_sample_count","edge_visible_weight"))
                if not r["matched"] or not case_supported:
                    continue
                a,b = r["baseline"][metric],r["candidate"][metric]
                if a < gates["floor"] and b > gates["floor"] or b-a > max(gates["maximumCaseAbsoluteRegression"],a*gates["maximumCaseRelativeRegression"]):
                    failures.append(f"per-case {metric}: {r['scene']}/{r['value']}")
        for r in subset:
            if not r["matched"]:
                continue
            for metric, limit in manifest["criticalGates"].items():
                if r["candidate"][metric] - r["baseline"][metric] > limit:
                    failures.append(f"critical {metric}: {r['scene']}/{r['value']}")
        # Quality outcomes are independent of missing photo/backend/perf evidence.
        status = "no-go" if failures else ("blocked" if missing else "pass")
        decisions[control] = {"qualityDecision": status, "failures": sorted(set(failures)), "missingQualityEvidence": sorted(set(missing)), "means": means,
                              "promotionDecision": "no-go", "promotionMissingEvidence": manifest["requiredEvidence"]}
    return decisions


def performance_pair(baseline, candidate, manifest):
    p = manifest["performance"]
    if baseline["inputSHA256"] != candidate["inputSHA256"] or not valid_hash(baseline["inputSHA256"]):
        raise ValueError("Timing sources differ")
    a,b = baseline["samples"],candidate["samples"]
    if len(a) != len(b) or any(sum(r["phase"] == phase for r in group) != amount for group in (a,b) for phase,amount in (("cold",1),("warmup",1),("warm",p["warmSamples"]))) or any(not finite(r.get(k)) or r[k] <= 0 for group in (a,b) for r in group for k in ("milliseconds","rss")):
        raise ValueError("Invalid timing samples")
    matched = all(x["phase"] == y["phase"] and matches(x["reduction"],y["reduction"],manifest) for x,y in zip(a,b))
    if not matched:
        return {"decision":"blocked", "reason":"Timing does not have equal positive noise reduction"}
    ratios = {phase: statistics.median(y["milliseconds"] for y in b if y["phase"] == phase)/statistics.median(x["milliseconds"] for x in a if x["phase"] == phase) for phase in ("cold","warm")}
    ratios["rss"] = max(y["rss"] for y in b)/max(x["rss"] for x in a)
    return {"decision": "pass" if ratios["cold"] <= p["maximumColdRatio"] and ratios["warm"] <= p["maximumWarmRatio"] and ratios["rss"] <= p["maximumRSSRatio"] else "no-go", "ratios":ratios}


def scale_decision(scale, manifest):
    p = manifest["scaling"]
    keys = [(r["control"],r["value"],r["variant"],r["width"],r["height"]) for r in scale["records"]]
    expected_keys = {(c,v,a,w,h) for c in manifest["controls"] for v in manifest["values"] for a in p["variants"] for w,h in p["previewSizes"]}
    if len(set(keys)) != len(keys) or set(keys) != expected_keys:
        raise ValueError("Incomplete scale matrix")
    failures = []
    native_outputs = {}
    for r in scale["records"]:
        if any(not valid_hash(r.get(k)) for k in ("fullInputSHA256","fullOutputSHA256","inputSHA256")):
            raise ValueError("Missing scale provenance")
        key = (r["control"],r["value"],r["variant"])
        pair = (r["fullInputSHA256"],r["fullOutputSHA256"])
        if key in native_outputs and native_outputs[key] != pair:
            raise ValueError("Native scale output changed between previews")
        native_outputs[key] = pair
        if r["variant"] == "glowroom":
            continue
        for metric in p["qualityMetrics"]:
            a,b = r["nativeQuality"].get(metric),r["directQuality"].get(metric)
            if not finite(a) or not finite(b):
                raise ValueError("Missing scale ground-truth quality")
            if b-a > max(p["maximumQualityAbsoluteRegression"],a*p["maximumQualityRelativeRegression"]):
                failures.append("scale quality " + metric)
        for c in components(r["control"]):
            a,b = r["nativeReduction"][c],r["directReduction"][c]
            if not finite(a) or not finite(b) or a < manifest["matching"]["minimumTarget"] or b <= 0 or abs(a-b) > max(p["maximumNoiseReductionAbsoluteError"],abs(a)*p["maximumNoiseReductionRelativeError"]):
                failures.append("scale strength")
        for metric, cap in [("distance_rgb_rmse","maximumRGBDistance"),("distance_luma_rmse","maximumLumaDistance"),("distance_chroma_rmse","maximumChromaDistance"),("alpha_error","maximumAlphaError")]:
            if not finite(r["distance"].get(metric)) or r["distance"][metric] > p[cap]:
                failures.append(metric)
    return {"decision":"no-go" if failures else "pass", "failures":sorted(set(failures))}


def execute(args):
    output = args.output.resolve(); output.mkdir(parents=True,exist_ok=False)
    source_manifest = HERE / "manifest.json"; manifest = json.loads(source_manifest.read_text()); validate_manifest(manifest)
    frozen = output / "manifest.json"; frozen.write_bytes(source_manifest.read_bytes())
    source_files = list((ROOT/"Sources").rglob("*.swift")) + [ROOT/"Package.swift", ROOT/"Package.resolved", Path(__file__), source_manifest]
    hashes = {str(p.relative_to(ROOT)):digest(p) for p in sorted(source_files)}
    binary_hash = digest(args.binary); manifest_hash = digest(frozen)
    environment = {"baseCommit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),"toolchain":subprocess.check_output(["xcrun","swift","--version"],text=True).strip(),"logicalCPUs":os.cpu_count(),"workingFormat":"RGBAf, extended linear sRGB, consistentV2","candidateBackend":"bounded CPU only; no GPU execution attribution","sourceHashes":hashes,"binarySHA256":binary_hash,"manifestSHA256":manifest_hash,"architecture":platform.machine(),"platform":platform.platform(),"sourceDecode":"none; shared frozen developed synthetic float rasters","performanceConcurrency":1,"productionChanged":False}
    write(output/"environment.json",environment)
    calibration = output / "tuning/calibration.json"
    def unchanged():
        if digest(args.binary) != binary_hash or digest(frozen) != manifest_hash or any(digest(ROOT/p) != h for p,h in hashes.items()):
            raise ValueError("Frozen sources/binary/protocol changed")
    def invoke(mode, name, adapter="glowroom", size=None):
        unchanged()
        command = [str(args.binary.resolve()),"--scenario","evaluation","--evaluation-mode","multiscale-denoise-"+mode,"--output",str(output/name),"--manifest",str(frozen),"--workers","1","--backend","default","--adapter",adapter,"--iterations","5"]
        if mode != "tune": command += ["--calibration",str(calibration)]
        if size: command += ["--width",str(size[0]),"--height",str(size[1])]
        with (output/(name+".log")).open("w") as log: subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        unchanged()
    invoke("tune","tuning"); tuning=json.loads(calibration.read_text()); calibration_hash=digest(calibration)
    validate_calibration(tuning,manifest)
    if tuning["manifestSHA256"] != manifest_hash: raise ValueError("Calibration protocol differs")
    invoke("quality","quality"); quality=json.loads((output/"quality/quality.json").read_text())
    if digest(calibration) != calibration_hash or quality["manifestSHA256"] != manifest_hash or quality["calibrationSHA256"] != calibration_hash: raise ValueError("Acceptance protocol/calibration changed")
    validate_calibration(tuning,manifest,quality)
    decisions=quality_decisions(quality,manifest)
    timings=[]; scaling=None
    if args.extended:
        # Serial processes are required for meaningful CPU/GPU/RSS comparison.
        for control in ("luminance","chroma"):
            for size in manifest["performance"]["sizes"]:
                for repeat in range(manifest["performance"]["coldProcesses"]):
                    pair={}
                    order=("glowroom","multiscale") if repeat%2 == 0 else ("multiscale","glowroom")
                    for adapter in order:
                        name=f"timing-{control}-{size[0]}-{repeat}-{adapter}";invoke("timing",name,adapter+"-"+control,size)
                        pair[adapter]=json.loads((output/name/"timing.json").read_text())
                    timings.append({"control":control,"size":size,"repeat":repeat,**performance_pair(pair["glowroom"],pair["multiscale"],manifest)})
        invoke("scale","scale");scaling=scale_decision(json.loads((output/"scale/scale.json").read_text()),manifest)
    gallery=["<!doctype html><meta charset='utf-8'><title>#175 matched quality pairs</title><style>img{width:384px}section{margin:24px}</style>"]
    for r in quality["records"]:
        name=r["directory"];gallery.append(f"<section><h2>{html.escape(name)}; matched={r['matched']}</h2>"+"".join(f"<figure><img src='quality/{name}-{label}.png'><figcaption>{label}</figcaption></figure>" for label in ("clean","noisy","baseline","candidate"))+"</section>")
    (output/"gallery.html").write_text("\n".join(gallery))
    for decision in decisions.values():
        missing = decision["promotionMissingEvidence"]
        if len(timings) == 40 and all(item["decision"] == "pass" for item in timings):
            missing = [item for item in missing if item != "matched cold/warm/RSS performance at every size"]
        if scaling and scaling["decision"] == "pass":
            missing = [item for item in missing if item != "preview/native scale matrix"]
        decision["promotionMissingEvidence"] = missing
    unchanged()
    write(output/"summary.json",{"manifestSHA256":manifest_hash,"calibrationSHA256":calibration_hash,"decisions":decisions,"performance":timings,"scale":scaling,"productionChanged":False})
    print(output/"summary.json",flush=True)


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output",type=Path);parser.add_argument("--binary",type=Path,required=True)
    parser.add_argument("--extended",action="store_true",help="Serial isolated timing and native/preview matrix; no concurrent build/benchmark")
    execute(parser.parse_args())

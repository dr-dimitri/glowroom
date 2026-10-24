#!/usr/bin/env python3
"""Reproducible local research CLI. Audit exit 2 means research No-Go."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys

from adapters import FileSnapshot, OnnxCPU, SNAPSHOT_BUDGET, SegNext, load_npy, match_gain, numpy, prepare_segnext, project_segnext, sha256, tensor, tiled
from contracts import PromptFrame, REVISION, segnext_gate

ROOT = Path(__file__).resolve().parent


def read_json(source):
    snapshot = source if isinstance(source,FileSnapshot) else FileSnapshot.read(source)
    def unique_object(pairs):
        result = {}
        for key,value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(snapshot.data, object_pairs_hook=unique_object,
                      parse_constant=lambda v: (_ for _ in ()).throw(ValueError(f"invalid JSON constant {v}")))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Results never overwrite originals, a prior measurement, or a frozen protocol.
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False, allow_nan=False)
        stream.write("\n")


def freeze_files(paths, max_bytes=SNAPSHOT_BUDGET):
    # Snapshot reads stay serial: their common memory admission must account for
    # all retained model/input bytes before another large allocation is made.
    remaining, result = min(max_bytes,SNAPSHOT_BUDGET), {}
    for path in paths:
        key = str(path)
        if key not in result:
            result[key] = FileSnapshot.read(path,remaining)
            remaining -= len(result[key].data)
    return result


def verify_files(frozen):
    if any(sha256(path) != snapshot.digest for path,snapshot in frozen.items()):
        raise ValueError("research input/model/receipt changed during inference")


def git(source, *args):
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def audit(source):
    source = Path(source).resolve()
    pins = read_json(ROOT/"source-pins.json")
    if git(source, "rev-parse", "HEAD") != REVISION:
        raise ValueError("darktable-ai HEAD differs from frozen source revision")
    def inspect(item):
        relative, expected = item
        path = source/relative
        actual = sha256(path) if path.is_file() else None
        return {"path":relative, "expected_sha256":expected, "actual_sha256":actual, "matches":actual == expected}
    # Independent disk reads overlap, capped at four; tiny contract maths stays serial.
    with ThreadPoolExecutor(max_workers=4) as pool:
        files = list(pool.map(inspect, pins["files"].items()))
    if not all(f["matches"] for f in files):
        raise ValueError("source bytes differ from frozen revision")
    vendors = {}
    for name, expected in pins["vendors"].items():
        entry = git(source, "ls-tree", "HEAD", f"vendor/{name}")
        actual = entry.split()[2] if entry else None
        if actual != expected:
            raise ValueError(f"unexpected vendor gitlink: {name}")
        checkout = source/"vendor"/name
        initialized = (checkout/".git").exists()
        vendors[name] = {"gitlink":actual, "initialized":initialized}
        if initialized:
            vendors[name]["checkout_revision"] = git(checkout, "rev-parse", "HEAD")
            vendors[name]["checkout_clean"] = not git(checkout, "status", "--porcelain")
            if vendors[name]["checkout_revision"] != expected or not vendors[name]["checkout_clean"]:
                raise ValueError(f"unfrozen vendor checkout: {name}")
    observations = {}
    for model, names in pins["artifacts"].items():
        observations[model] = []
        for relative in names:
            path = source/relative
            observations[model].append({"path":relative, "exists":path.is_file(),
                                         "observed_sha256":sha256(path) if path.is_file() else None,
                                         "frozen_sha256":None, "qualified":False})
    raw_yaml = (source/"models/rawdenoise-nind/model.yaml").read_text()
    versions = {}
    for name in ("numpy", "Pillow", "onnxruntime", "coremltools", "torch", "onnx"):
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
    missing = {
        "182": ["checkpoint/export SHA-256 and converter execution receipt", "reviewed HQSeg-44K per-dataset conditions",
                "twelve licensed photographs, independent binary GT and frozen starts/clicks", "separate tuning split",
                "native Core ML/reference parity", "named-Mac encoder/first/warm decoder/peak-RSS measurements",
                "AIResourceBudget and cache/cancellation/image-switch app qualification"],
        "183": ["checkpoint/export SHA-256 and converter execution receipt", "separate code/weight attribution review",
                "native Core ML/reference parity", "frozen fair-effect tuning and acceptance pairs against consistentV2",
                "real developed camera-photo GT/review and preview/native export comparisons",
                "named-Mac load/inference/app-preview/export/peak-RSS measurements", "AIResourceBudget app qualification"],
        "187": ["controlled native pre-tone/pre-clipping linear Rec.2020 input provider", "native Bayer sensor/metadata decoder contract",
                "checkpoint/export SHA-256 and converter execution receipt", "GPL-3.0 integration-mode/attribution decision",
                "reference RAW/clean pairs and sensor-specific metadata", "CPU/native parity, finite intermediates and FP16 overflow investigation",
                "gain/colour/crop/preview/export consistency and resource measurements"]}
    return {"schema":"glowroom-dtai-study-audit-v1", "source_revision":REVISION,
            "source_files":files, "vendors":vendors, "artifacts":observations,
            "host":{"system":platform.system(), "machine":platform.machine(), "release":platform.release()},
            "tool_versions":versions,
            "raw_bayer_cpu_guard":{"readme_claims_cpu_only":True, "yaml_has_cpu_only": "\ncpu_only:" in "\n"+raw_yaml,
                                  "decision":"unqualified; research adapter allows CPU FP32 only"},
            "issues":{number:{"decision":"no-go", "scope":"product integration", "missing_evidence":reasons}
                      for number,reasons in missing.items()},
            "photo_metrics":None, "native_parity":None, "resource_measurements":None,
            "decision":"no-go", "reason":"required evidence unavailable; contract smoke tests are not model qualification"}


def receipt(source, variant, pin_source=None):
    value = read_json(source)
    pin = read_json(pin_source if pin_source is not None else ROOT/"source-pins.json")
    model = {"nafnet":"NAFNet", "raw-linear":"rawnind_jddc", "raw-bayer":"rawnind_jddc", "segnext":"SegNext"}[variant]
    if value.get("source_revision") != REVISION or value.get("vendor_revision") != pin["vendors"][model]:
        raise ValueError("receipt source/vendor revision mismatch")
    for field in ("checkpoint_sha256", "converter_sha256", "model_sha256"):
        digest = value.get(field, "")
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError(f"receipt requires {field}")
    directory = {"nafnet":"denoise-nafnet", "raw-linear":"rawdenoise-nind", "raw-bayer":"rawdenoise-nind", "segnext":"mask-object-segnext-b2hq"}[variant]
    if value["converter_sha256"] != pin["files"][f"models/{directory}/convert.py"]:
        raise ValueError("receipt converter differs from pinned source")
    versions = value.get("tool_versions")
    if (value.get("precision") != "float32" or value.get("opset") != 20 or
        not isinstance(versions,dict) or not versions or
        any(not isinstance(k,str) or not k or not isinstance(v,str) or not v for k,v in versions.items())):
        raise ValueError("FP32/opset20 and explicit conversion tool versions required")
    return value


def infer_denoise(args):
    np = numpy()
    frozen = freeze_files((args.receipt,args.input,args.model,ROOT/"source-pins.json"))
    value = receipt(frozen[str(args.receipt)], args.variant, frozen[str(ROOT/"source-pins.json")])
    size, channels, scale, space = {"nafnet":(768,3,1,"encoded-srgb"),
                                    "raw-linear":(512,3,1,"linear-rec2020"),
                                    "raw-bayer":(512,4,2,"packed-camera-rggb")}[args.variant]
    if args.color_space != space:
        raise ValueError(f"explicit {space} input required")
    arr = load_npy(frozen[str(args.input)])
    tensor(arr, channels, unit_range=True)
    if Path(args.output).exists() or Path(args.report).exists():
        raise ValueError("output and report must be new")
    session = OnnxCPU(frozen[str(args.model)], value["model_sha256"],
                       {"input":("tensor(float)",(1,channels,size,size))},
                       {"output":("tensor(float)",(1,3,size*scale,size*scale))})
    result = tiled(arr, lambda tile:session.run({"input":tile})[0], tile_size=size, scale=scale)
    gain = None
    if args.variant.startswith("raw-"):
        result, gain = match_gain(result, arr)
    verify_files(frozen)
    # Bayer stays camera RGB until an explicit qualified matrix is supplied.
    # Raw output is neither clipped nor exposure-matched to a clean target.
    with open(args.output, "xb") as stream:
        np.save(stream, result, allow_pickle=False)
    write_json(args.report, {"schema":"glowroom-dtai-reference-v1", "variant":args.variant,
               "model_sha256":session.sha256, "input_sha256":frozen[str(args.input)].digest, "output_sha256":sha256(args.output),
               "receipt_sha256":frozen[str(args.receipt)].digest, "runner_sha256":sha256(__file__), "adapters_sha256":sha256(ROOT/"adapters.py"),
               "tool_versions":{name:importlib.metadata.version(name) for name in ("numpy","onnx","onnxruntime")},
               "provider":"CPUExecutionProvider", "load_seconds":session.load_seconds,
               "tile_seconds":session.timings, "input_shape":list(arr.shape), "output_shape":list(result.shape),
               "gain":gain, "output_space":"camera-rgb" if args.variant == "raw-bayer" else space,
               "qualified":False, "decision":"reference-only; native and photographic gates outstanding"})


def infer_segnext(args):
    np = numpy()
    frozen = freeze_files((args.encoder_receipt,args.decoder_receipt,args.input,args.frame,args.clicks,args.encoder,args.decoder,ROOT/"source-pins.json"))
    enc_receipt = receipt(frozen[str(args.encoder_receipt)], "segnext", frozen[str(ROOT/"source-pins.json")])
    dec_receipt = receipt(frozen[str(args.decoder_receipt)], "segnext", frozen[str(ROOT/"source-pins.json")])
    if enc_receipt["checkpoint_sha256"] != dec_receipt["checkpoint_sha256"]:
        raise ValueError("encoder/decoder must come from the same checkpoint")
    if args.output.exists():
        raise ValueError("output directory must be new")
    frame_data = read_json(frozen[str(args.frame)])
    frame = PromptFrame(**frame_data)
    clicks = read_json(frozen[str(args.clicks)])
    if not 1 <= len(clicks) <= 10:
        raise ValueError("one to ten frozen clicks required")
    image = prepare_segnext(load_npy(frozen[str(args.input)]),frame)
    encoder = OnnxCPU(frozen[str(args.encoder)], enc_receipt["model_sha256"],
                      {"image":("tensor(float)",(1,3,1024,1024))},
                      {"image_feats":("tensor(float)",(1,768,64,64))})
    decoder = OnnxCPU(frozen[str(args.decoder)], dec_receipt["model_sha256"],
                      {"image_feats":("tensor(float)",(1,768,64,64)),
                       "point_coords":("tensor(float)",(1,"num_points",2)),
                       "point_labels":("tensor(float)",(1,"num_points")),
                       "prev_mask":("tensor(float)",(1,1,1024,1024))},
                      {"mask":("tensor(float)",(1,1,1024,1024))})
    adapter = SegNext(encoder,decoder)
    args.output.mkdir(parents=True)
    previous, outputs = None, []
    for index in range(len(clicks)):
        previous = adapter.refine(image,frame,clicks[:index+1],previous=previous)
        verify_files(frozen)
        path = args.output/f"click-{index+1:02d}.npy"
        with path.open("xb") as stream:
            np.save(stream,project_segnext(previous["logits"],frame),allow_pickle=False)
        outputs.append({"click":index+1,"mask_sha256":sha256(path)})
    write_json(args.output/"report.json", {"schema":"glowroom-segnext-reference-v1",
               "source_revision":REVISION,"frame_id":frame.identity,"input_sha256":frozen[str(args.input)].digest,
               "frame_sha256":frozen[str(args.frame)].digest,"clicks_sha256":frozen[str(args.clicks)].digest,
               "encoder_sha256":encoder.sha256,"decoder_sha256":decoder.sha256,
               "encoder_receipt_sha256":frozen[str(args.encoder_receipt)].digest,"decoder_receipt_sha256":frozen[str(args.decoder_receipt)].digest,
               "tool_versions":{name:importlib.metadata.version(name) for name in ("numpy","Pillow","onnx","onnxruntime")},
               "outputs":outputs,"encoder_seconds":encoder.timings,"decoder_seconds":decoder.timings,
               "provider":"CPUExecutionProvider","prev_mask":"binary-float32-0-1",
               "preparation":"Float-channel Lanczos SDR clip v1; uint8 reference parity unqualified",
               "threshold":">0 logits -> uint8 Lanczos -> >127 -> inverse geometry; no alpha/matting assertion",
               "qualified":False,"decision":"reference-only; frozen photographs/native parity outstanding"})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("audit")
    command.add_argument("--source", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command = sub.add_parser("segnext-gate", help="score recorded IoUs; never grants product Go")
    command.add_argument("--cases", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command = sub.add_parser("denoise", help="explicit FP32 ONNX CPU reference; no image decode or download")
    command.add_argument("--variant", choices=("nafnet", "raw-linear", "raw-bayer"), required=True)
    for name in ("model", "receipt", "input", "output", "report"):
        command.add_argument(f"--{name}", type=Path, required=True)
    command.add_argument("--color-space", required=True)
    command = sub.add_parser("segnext", help="source-scoped interactive reference proposals")
    for name in ("encoder", "decoder", "encoder-receipt", "decoder-receipt", "input", "frame", "clicks", "output"):
        command.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "audit":
            result = audit(args.source)
            write_json(args.output, result)
            print(f"NO-GO: issues 182, 183, 187; evidence report: {args.output}")
            return 2
        if args.command == "segnext-gate":
            result = segnext_gate(read_json(args.cases))
            write_json(args.output, result)
            return 2 if result["quality"] == "no-go" else 0
        if args.command == "segnext":
            infer_segnext(args)
        else:
            infer_denoise(args)
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"evaluation refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

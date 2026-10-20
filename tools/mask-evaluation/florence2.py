#!/usr/bin/env python3
"""Evaluate the exact official Microsoft Florence-2-large checkpoint locally."""
import argparse
import concurrent.futures
import hashlib
import importlib.metadata
import inspect
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import time
import traceback

REPOSITORY = "microsoft/Florence-2-large"
REVISION = "21a599d414c4d928c9032694c424fb94458e3594"
FILES = {
    "model.safetensors": (1553563458, "4f38ce741c6b71188fe2b3419a55e11917a8a7b321ae2e63c61da0191b0ebad7"),
    "config.json": (2445, "6f8a8f92a74ce18b5c1e5646b4a8222477dd1ac49f31b953e75d6fc3e0f8583a"),
    "preprocessor_config.json": (806, "2f5921bbc53c7cc04251e1027b45b1cec726276be6db23d1bb40641bfbe2cf29"),
    "generation_config.json": (51, "30e9865458ecc8ee931eeeb43f44f1d169c5ab95be39e0072142a7a6b8f31990"),
    "configuration_florence2.py": (15119, "de2e45a975b3582de05d2f4d963a3e9f9a3d20dccf78d28e0052932a0be93bdf"),
    "modeling_florence2.py": (127455, "5162bf465e61b6e29cc113a467630ec3cb56ed8e4d46eb6207157f10fb9b8a24"),
    "processing_florence2.py": (48674, "c655782a9e4347965c735ea54cbc4e98fdbc02155ffd1ce2ecd61f42c45eda28"),
    "tokenizer.json": (1355863, "847bbeab6174d66a88898f729d52fa8d355fafe1bea101cf960dd404581df70e"),
    "tokenizer_config.json": (34, "79ffcf43af8ebda99d165f61d243180da2e2639952e41e71e11611c18770489c"),
    "vocab.json": (1099884, "394fdc63c71aabe0a9b97117f5d62fb5fcc4d59b2b3ea929a3929e6a53217b3c"),
    "LICENSE": (1141, "c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383"),
    "README.md": (16315, "16212f1929e4992649d18b812e0ebf7ebbbaffd90a5ba23dfdc5c78df2f92ac2"),
}
TASKS = {
    "referring-segmentation": "<REFERRING_EXPRESSION_SEGMENTATION>",
    "phrase-grounding": "<CAPTION_TO_PHRASE_GROUNDING>",
}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def memory(torch, device):
    # Darwin ru_maxrss is bytes. RSS is a process high-water mark, not model size.
    result = {"processPeakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    if device == "mps":
        result.update(mpsCurrentAllocatedBytes=torch.mps.current_allocated_memory(),
                      mpsDriverAllocatedBytes=torch.mps.driver_allocated_memory())
    return result


def runtime_source(cls, filename):
    path = Path(inspect.getfile(cls))
    expected = FILES[filename][1]
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f"Executed Microsoft source differs from verified original: {filename}")
    return {"class": f"{cls.__module__}.{cls.__name__}", "file": str(path), "sha256": actual}


def raw_syntax(text, task):
    runs = re.findall(r"(?:<loc_\d+>)+", text)
    counts = [len(re.findall(r"<loc_\d+>", run)) for run in runs]
    locations = [int(x) for x in re.findall(r"<loc_(\d+)>", text)]
    result = {"coordinateRunLengths": counts, "coordinateCount": len(locations),
              "coordinateBinsInRange": all(0 <= x < 1000 for x in locations),
              "polygonOpenTags": text.count("<poly>"),
              "polygonCloseTags": text.count("</poly>")}
    polygon = task == "referring-segmentation"
    result["rawCoordinateRunsValid"] = all(n >= 6 and n % 2 == 0 for n in counts) if polygon else all(n % 4 == 0 for n in counts)
    result["polygonTagsBalanced"] = result["polygonOpenTags"] == result["polygonCloseTags"]
    # Microsoft permits polygons without <poly> wrappers; balanced zero tags is valid.
    return result


def rasterize(parsed, task, size, path):
    from PIL import Image, ImageDraw
    import numpy as np
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    width, height = size
    invalid = 0
    outside = 0
    polygon_count = 0
    box_count = 0
    if task == "referring-segmentation":
        instances = parsed.get("polygons", [])
        for instance in instances:
            for flat in instance:
                if len(flat) < 6 or len(flat) % 2 or not all(math.isfinite(float(x)) for x in flat):
                    invalid += 1
                    continue
                points = list(zip(flat[0::2], flat[1::2]))
                outside += sum(not (0 <= x < width and 0 <= y < height) for x, y in points)
                area = abs(sum(points[i][0] * points[(i + 1) % len(points)][1] - points[(i + 1) % len(points)][0] * points[i][1] for i in range(len(points)))) / 2
                if area == 0:
                    invalid += 1
                    continue
                draw.polygon(points, fill=255)
                polygon_count += 1
        instance_count = len(instances)
    else:
        boxes = parsed.get("bboxes", [])
        for box in boxes:
            if len(box) != 4 or not all(math.isfinite(float(x)) for x in box):
                invalid += 1
                continue
            x1, y1, x2, y2 = box
            if x2 <= x1 or y2 <= y1:
                invalid += 1
                continue
            outside += sum(not (0 <= x < width and 0 <= y < height) for x, y in [(x1, y1), (x2, y2)])
            draw.rectangle(box, fill=255)
            box_count += 1
        instance_count = len(boxes)
    mask.save(path)
    return {"instanceCount": instance_count, "polygonCount": polygon_count,
            "boxCount": box_count, "invalidParsedShapes": invalid,
            "outOfBoundsVertices": outside, "nonzeroMaskPixels": int(np.count_nonzero(np.asarray(mask))),
            "maskSemantics": "Union of source-pixel polygons; binary segmentation, no alpha matting" if task == "referring-segmentation" else "Diagnostic union of bounding rectangles; not an object segmentation mask"}


def run(args):
    root = args.root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    report = {"schemaVersion": 1, "repository": REPOSITORY, "revision": REVISION,
              "status": "starting", "images": [], "device": args.device,
              "dtype": "float16" if args.device == "mps" else "float32",
              "generation": {"numBeams": args.beams, "doSample": False,
                             "maxNewTokens": args.max_new_tokens, "useCache": True},
              "maskSemantics": "Generated polygons rasterized in original proxy geometry; not alpha matting",
              "manualBoxesAndPointsUsed": False,
              "runDescription": "Each generate call includes image encoder and autoregressive text generation. Images decoded once per photo; no cross-task vision-feature cache.",
              "mpsFallbackEnvironment": os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK", "unset"),
              "platform": platform.platform(), "python": platform.python_version()}
    def save():
        write_json(output / "benchmark.json", report)
    save()
    try:
        report["verifiedArtifacts"] = [verify_file(root / "models", name) for name in FILES]
        report["verifyArtifactSeconds"] = time.perf_counter() - started
        import_start = time.perf_counter()
        import torch
        import numpy as np
        from PIL import Image
        from transformers import AutoModelForCausalLM, AutoProcessor
        from safetensors import safe_open
        report["importSeconds"] = time.perf_counter() - import_start
        report["versions"] = {name: importlib.metadata.version(name) for name in ["torch", "torchvision", "transformers", "huggingface_hub", "tokenizers", "accelerate", "timm", "einops", "numpy", "pillow", "safetensors"]}
        torch.set_num_threads(args.threads)
        torch.set_num_interop_threads(1)
        if args.device == "mps" and (not torch.backends.mps.is_available() or report["mpsFallbackEnvironment"] != "0"):
            raise RuntimeError("MPS run requires an available MPS device and PYTORCH_ENABLE_MPS_FALLBACK=0")
        dtype = torch.float16 if args.device == "mps" else torch.float32
        def sync():
            if args.device == "mps":
                torch.mps.synchronize()
        load_start = time.perf_counter()
        # Explicitly load only safetensors, with exact original Microsoft code.
        model, loading_info = AutoModelForCausalLM.from_pretrained(
            root / "models", trust_remote_code=True, local_files_only=True,
            use_safetensors=True, torch_dtype=dtype, attn_implementation="eager",
            output_loading_info=True)
        report["loadingInfo"] = loading_info
        if any(loading_info.get(key) for key in ["missing_keys", "unexpected_keys", "mismatched_keys", "error_msgs"]):
            raise ValueError("Checkpoint did not load completely; see loadingInfo")
        processor = AutoProcessor.from_pretrained(root / "models", trust_remote_code=True, local_files_only=True)
        # Microsoft delegates generation to language_model; its defaults can
        # differ from the outer generation_config.json. Retain both for audit.
        report["generationConfigInner"] = model.language_model.generation_config.to_dict()
        report["generationConfigOuter"] = model.generation_config.to_dict()
        report["executedMicrosoftSources"] = [runtime_source(type(model), "modeling_florence2.py"),
            runtime_source(type(model.config), "configuration_florence2.py"),
            runtime_source(type(processor), "processing_florence2.py")]
        with safe_open(root / "models" / "model.safetensors", framework="pt", device="cpu") as weights:
            state = model.state_dict()
            mismatches = []
            stored_elements = 0
            for name in weights.keys():
                shape = tuple(weights.get_slice(name).get_shape())
                stored_elements += math.prod(shape)
                if name not in state or tuple(state[name].shape) != shape:
                    mismatches.append(name)
            report["checkpointTensorCount"] = len(weights.keys())
            report["checkpointStoredElements"] = stored_elements
            if mismatches:
                raise ValueError(f"Original checkpoint tensor shape/key mismatch: {mismatches}")
        if report["checkpointTensorCount"] != 918 or report["checkpointStoredElements"] != 776721497:
            raise ValueError("Unexpected official large checkpoint tensor inventory")
        report["processor"] = {"class": type(processor).__name__, "imageProcessorClass": type(processor.image_processor).__name__,
            "imageProcessorSize": processor.image_processor.size, "tokenizerClass": type(processor.tokenizer).__name__,
            "tokenizerLength": len(processor.tokenizer),
            "supportedTasks": {task: processor.tasks_answer_post_processing_type.get(token) for task, token in TASKS.items()}}
        if any(value is None for value in report["processor"]["supportedTasks"].values()):
            raise ValueError("Original processor does not expose both requested tasks")
        model = model.eval().to(args.device)
        sync()
        report["modelAndProcessorLoadToDeviceSeconds"] = time.perf_counter() - load_start
        report["memoryAfterLoad"] = memory(torch, args.device)
        report["status"] = "running"
        save()
        manifest = json.loads(args.manifest.read_text())
        rows = manifest["images"]
        if args.image_id:
            rows = [row for row in rows if row["id"] == args.image_id]
            if not rows:
                raise ValueError("Requested image id is absent from manifest")
        if args.limit:
            rows = rows[:args.limit]
        for index, row in enumerate(rows):
            image_dir = output / row["id"]
            image_dir.mkdir(exist_ok=True)
            decode_start = time.perf_counter()
            with Image.open(row["path"]) as source:
                image = source.convert("RGB")
            image_report = {"id": row["id"], "target": row["target"], "sourceWidth": image.width,
                            "sourceHeight": image.height, "imageDecodeSeconds": time.perf_counter() - decode_start, "tasks": []}
            report["images"].append(image_report)
            for task_name, task_token in TASKS.items():
                if args.task and task_name != args.task:
                    continue
                task_dir = image_dir / task_name
                task_dir.mkdir(exist_ok=True)
                sync()
                request_start = time.perf_counter()
                inputs = processor(text=task_token + row["target"], images=image, return_tensors="pt")
                preprocess_seconds = time.perf_counter() - request_start
                transfer_start = time.perf_counter()
                input_ids = inputs["input_ids"].to(args.device)
                pixels = inputs["pixel_values"].to(device=args.device, dtype=dtype)
                sync()
                transfer_seconds = time.perf_counter() - transfer_start
                generation_start = time.perf_counter()
                with torch.inference_mode():
                    generated = model.generate(input_ids=input_ids, pixel_values=pixels,
                        max_new_tokens=args.max_new_tokens, num_beams=args.beams,
                        do_sample=False, use_cache=True)
                sync()
                generation_seconds = time.perf_counter() - generation_start
                post_start = time.perf_counter()
                ids = generated[0].detach().cpu().tolist()
                text = processor.batch_decode(generated.detach().cpu(), skip_special_tokens=False)[0]
                parsed = processor.post_process_generation(text, task=task_token, image_size=(image.width, image.height))
                payload = parsed[task_token]
                syntax = raw_syntax(text, task_name)
                decoder_start = model.config.text_config.decoder_start_token_id
                content_ids = ids[1:] if ids and ids[0] == decoder_start else ids
                eos_id = model.config.text_config.eos_token_id
                eos_ids = eos_id if isinstance(eos_id, list) else [eos_id]
                eos_seen = any(token in eos_ids for token in content_ids)
                cap = len(content_ids) >= args.max_new_tokens
                parsed_seconds = time.perf_counter() - post_start
                mask_name = "mask.png" if task_name == "referring-segmentation" else "box-union.png"
                raster_start = time.perf_counter()
                raster = rasterize(payload, task_name, image.size, task_dir / mask_name)
                raster_seconds = time.perf_counter() - raster_start
                complete = eos_seen and not cap and syntax["rawCoordinateRunsValid"] and syntax["polygonTagsBalanced"] and syntax["coordinateBinsInRange"] and raster["invalidParsedShapes"] == 0 and raster["outOfBoundsVertices"] == 0
                task_report = {"task": task_name, "taskToken": task_token,
                    "preprocessSeconds": preprocess_seconds, "inputTransferSeconds": transfer_seconds,
                    "generateSeconds": generation_seconds, "decodeAndOfficialParseSeconds": parsed_seconds,
                    "rasterAndMaskSaveSeconds": raster_seconds,
                    "requestToParsedOutputSeconds": preprocess_seconds + transfer_seconds + generation_seconds + parsed_seconds,
                    "requestToSavedMaskSeconds": time.perf_counter() - request_start,
                    "inputShape": list(pixels.shape), "sequenceTokenCount": len(ids),
                    "generatedTokenCountExcludingDecoderStart": len(content_ids),
                    "eosAfterDecoderStart": eos_seen, "tokenCapReached": cap,
                    "truncationRisk": cap or not eos_seen or not syntax["polygonTagsBalanced"],
                    "syntax": syntax, "outputCompleteByChecks": complete,
                    "hasNonemptyParsedOutput": raster["instanceCount"] > 0,
                    "raster": raster, "memory": memory(torch, args.device)}
                # These artifacts are intentionally private: they reconstruct masks.
                (task_dir / "raw-text.txt").write_text(text)
                write_json(task_dir / "token-ids.json", ids)
                write_json(task_dir / "parsed.json", parsed)
                write_json(task_dir / "benchmark.json", task_report)
                image_report["tasks"].append(task_report)
                save()
                print(json.dumps({"id": row["id"], "task": task_name, "generateSeconds": generation_seconds,
                    "tokens": len(content_ids), "instances": raster["instanceCount"], "complete": complete,
                    "cap": cap, "peakRSSBytes": task_report["memory"]["processPeakRSSBytes"]}), flush=True)
            image.close()
        report["status"] = "completed"
        report["totalWallSeconds"] = time.perf_counter() - started
        report["finalMemory"] = memory(torch, args.device)
        save()
    except KeyboardInterrupt:
        report.update(status="interrupted", totalWallSeconds=time.perf_counter() - started)
        save()
        raise SystemExit(130)
    except Exception as error:
        report.update(status="failed", errorType=type(error).__name__, error=str(error), traceback=traceback.format_exc())
        save()
        raise


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def verify_file(directory, name):
    path = directory / name
    size, expected = FILES[name]
    if path.stat().st_size != size or sha256(path) != expected:
        raise ValueError(f"Pinned Microsoft artifact integrity mismatch: {name}")
    return {"path": name, "bytes": size, "sha256": expected}


def download(root):
    from huggingface_hub import hf_hub_download
    import importlib.metadata

    root.mkdir(parents=True, exist_ok=True)
    def fetch(name):
        hf_hub_download(REPOSITORY, filename=name, revision=REVISION,
            local_dir=root / "models", cache_dir=root / "hf-cache", token=False)
        return verify_file(root / "models", name)
    # The single weight file and small independent metadata files can overlap.
    # Limit concurrent network activity and hashing to three workers.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(fetch, FILES))
    provenance = {"repository": REPOSITORY, "revision": REVISION, "files": results,
        "totalBytes": sum(x["bytes"] for x in results),
        "huggingfaceHubVersion": importlib.metadata.version("huggingface_hub"),
        "checkpointIdentity": "Official current Microsoft large continued-pretrained 4k version; not large-ft or a community conversion",
        "license": "MIT model license; Microsoft Python source headers also carry Apache-2.0 notices"}
    (root / "download-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps({"repository": REPOSITORY, "revision": REVISION,
        "files": len(results), "totalBytes": provenance["totalBytes"]}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    dl = subparsers.add_parser("download")
    dl.add_argument("root", type=Path)
    evaluation = subparsers.add_parser("run")
    evaluation.add_argument("root", type=Path)
    evaluation.add_argument("--manifest", type=Path, required=True)
    evaluation.add_argument("--output", type=Path, required=True)
    evaluation.add_argument("--device", choices=["mps", "cpu"], default="mps")
    evaluation.add_argument("--threads", type=int, default=4)
    evaluation.add_argument("--beams", type=int, default=3)
    evaluation.add_argument("--max-new-tokens", type=int, default=1024)
    evaluation.add_argument("--limit", type=int)
    evaluation.add_argument("--image-id")
    evaluation.add_argument("--task", choices=list(TASKS))
    args = parser.parse_args()
    if args.command == "download":
        download(args.root.resolve())
    else:
        if args.beams < 1 or args.max_new_tokens < 1 or args.threads < 1:
            parser.error("beams, max-new-tokens and threads must be positive")
        run(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Evaluate a pinned JarvisArt model through an already running local llama-server.

This runner downloads nothing. Independent source verification and raster
preparation use three workers; inference uses one server slot serially to avoid
competing model allocations and preserve per-image measurements.
"""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from hashlib import sha256
import importlib.util
from io import BytesIO
import ipaddress
import json
import math
from pathlib import Path
import platform
import socket
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from PIL import Image
import psutil


_SPEC = importlib.util.spec_from_file_location("jarvis_common_runner", Path(__file__).with_name("run.py"))
common = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(common)
MAX_SERVER_RESPONSE_BYTES = 1_048_576


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise ValueError("local inference redirects are forbidden")


def local_endpoint(value):
    """Pin localhost to a literal address; never use DNS, proxies or redirects."""
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        raise ValueError("server URL must be a credential-free loopback HTTP URL")
    host = parsed.hostname
    if host == "localhost":
        host = "127.0.0.1"
    try:
        address = ipaddress.ip_address(host or "")
        port = parsed.port
    except ValueError as error:
        raise ValueError("server URL must use a literal loopback address or localhost") from error
    if not address.is_loopback or port is None:
        raise ValueError("server URL must use an explicit loopback port")
    if parsed.path not in ("", "/", "/v1", "/v1/", "/v1/chat/completions"):
        raise ValueError("server URL must identify the local chat-completions endpoint")
    authority = f"[{address}]:{port}" if address.version == 6 else f"{address}:{port}"
    return urlunsplit((parsed.scheme, authority, "/v1/chat/completions", "", ""))


def strict_json(text):
    def invalid_constant(value):
        raise ValueError("non-finite JSON constant: " + value)

    def finite_float(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("non-finite JSON float")
        return result

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result

    return json.loads(text, parse_constant=invalid_constant, parse_float=finite_float,
                      object_pairs_hook=unique_object)


def read_json(path):
    return strict_json(path.read_text(encoding="utf-8"))


def verify_provenance(path, require_files=True):
    value = read_json(path)
    if not isinstance(value, dict):
        raise ValueError("provenance must be a JSON object")
    entries = value.get("files", [])
    if not isinstance(entries, list) or (require_files and not entries):
        raise ValueError("provenance must enumerate hashed local files")
    root = Path(value.get("root", value.get("model_dir", path.parent))).resolve()

    def verify(entry):
        if not isinstance(entry, dict):
            raise ValueError("invalid provenance file entry")
        name = entry.get("file")
        if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("provenance file must be relative to its root")
        target = (root / name).resolve()
        if not target.is_relative_to(root):
            raise ValueError("provenance file escapes root")
        expected = entry.get("sha256")
        if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise ValueError("invalid provenance SHA-256")
        if target.stat().st_size != entry.get("bytes") or common.digest(target) != expected:
            raise ValueError("local provenance hash/size mismatch: " + name)
        return name

    # Model/mmproj/runtime reads are independent and bounded; no model is loaded.
    with ThreadPoolExecutor(max_workers=min(3, max(1, len(entries)))) as pool:
        checked = list(pool.map(verify, entries))
    if len(set(checked)) != len(checked):
        raise ValueError("duplicate provenance file")
    # Binding and saved provenance use the same resolved root, including when
    # the input intentionally relies on its provenance-file directory default.
    return {**value, "root": str(root)}


def verify_server_binding(server_pid, model, runtime, endpoint):
    """Bind hashed files to the actual process before any image is submitted."""
    process = psutil.Process(server_pid)
    executable = Path(process.exe()).resolve()
    arguments = process.cmdline()

    def declared_files(provenance):
        root = Path(provenance.get("root", provenance.get("model_dir", "."))).resolve()
        return {(root / entry["file"]).resolve() for entry in provenance["files"]}

    def argument_value(flags):
        values = []
        for index, argument in enumerate(arguments):
            if argument in flags:
                if index + 1 >= len(arguments):
                    raise ValueError("server option has no value: " + argument)
                values.append(arguments[index + 1])
            else:
                for flag in flags:
                    if argument.startswith(flag + "="):
                        values.append(argument[len(flag) + 1:])
        if len(values) != 1:
            raise ValueError("server must explicitly declare one " + "/".join(flags))
        return values[0]

    if executable not in declared_files(runtime):
        raise ValueError("running server executable is not a hashed runtime file")
    process_directory = Path(process.cwd())
    model_path = (process_directory / argument_value(("-m", "--model"))).resolve()
    mmproj_path = (process_directory / argument_value(("--mmproj",))).resolve()
    declared = declared_files(model)
    if (model_path == mmproj_path or any(path.suffix.lower() != ".gguf" or path not in declared
                                         for path in (model_path, mmproj_path))):
        raise ValueError("running server model/mmproj must be distinct hashed GGUF files")
    if argument_value(("-np", "--parallel")) != "1":
        raise ValueError("running server must have exactly one explicitly configured slot")
    requested = urlsplit(local_endpoint(endpoint))
    configured_host = argument_value(("--host",))
    if configured_host == "localhost":
        configured_host = "127.0.0.1"
    try:
        configured_address = ipaddress.ip_address(configured_host)
        configured_port = int(argument_value(("--port",)))
    except ValueError as error:
        raise ValueError("running server must explicitly configure the loopback endpoint") from error
    if (not configured_address.is_loopback or str(configured_address) != requested.hostname
            or configured_port != requested.port):
        raise ValueError("requested endpoint differs from running server host/port")
    return {"status": "verified", "pid": server_pid, "process_created_at_unix": process.create_time(),
            "executable": str(executable), "model_path": str(model_path), "mmproj_path": str(mmproj_path),
            "server_slots": 1, "endpoint": local_endpoint(endpoint),
            "endpoint_binding": "explicit_process_host_port_arguments"}


def make_request(prepared, prompt, mode, schema, system_prompt=None, model_name="jarvisart"):
    image = Image.frombytes("RGB", tuple(prepared["dimensions"]), prepared["pixels"])
    encoded = BytesIO()
    image.save(encoded, format="PNG")
    messages = []
    if system_prompt is not None:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(encoded.getvalue()).decode("ascii")}},
    ]})
    body = {"model": model_name, "messages": messages, "stream": False,
            "temperature": 0.0, "top_p": 1.0, "top_k": 0, "seed": 0,
            "max_tokens": 768 if mode == "shared" else 2048,
            "n_predict": 768 if mode == "shared" else 2048,
            "cache_prompt": False, "id_slot": 0}
    if mode == "shared":
        body["response_format"] = {"type": "json_schema", "json_schema": {
            "name": "glowroom_correction", "strict": True, "schema": common.grammar_schema(schema)}}
    return body


class ServerMonitor:
    """RSS of a known server process tree, separately from global OS counters."""
    def __init__(self, server_pid=None):
        self.psutil = psutil
        self.server = psutil.Process(server_pid) if server_pid is not None else None
        self.stop = threading.Event()
        self.thread = None
        self.rss = []
        self.available = []
        self.failures = []

    def sample(self):
        try:
            self.available.append(self.psutil.virtual_memory().available)
        except (self.psutil.Error, OSError) as error:
            self.failures.append("virtual_memory: " + type(error).__name__)
        if self.server is None:
            return
        try:
            if not self.server.is_running():
                raise self.psutil.NoSuchProcess(self.server.pid)
            processes = {p.pid: p for p in [self.server, *self.server.children(recursive=True)]}
            self.rss.append(sum(p.memory_info().rss for p in processes.values()))
        except (self.psutil.Error, OSError) as error:
            self.failures.append("server_rss: " + type(error).__name__)

    def swap_used(self):
        try:
            return self.psutil.swap_memory().used
        except (self.psutil.Error, OSError) as error:
            self.failures.append("swap_memory: " + type(error).__name__)
            return None

    def __enter__(self):
        self.swap_before = self.swap_used()
        self.sample()

        def monitor():
            while not self.stop.wait(.05):
                self.sample()

        self.thread = threading.Thread(target=monitor, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join(timeout=2)
        self.sample()
        swap_after = self.swap_used()
        self.metrics = {
            "server_tree_rss_sampled_peak_bytes": max(self.rss) if self.rss else None,
            "server_rss_sample_count": len(self.rss),
            "monitor_errors": sorted(set(self.failures)),
            "system_min_available_bytes": min(self.available) if self.available else None,
            "system_swap_used_delta_bytes": (swap_after - self.swap_before
                                             if swap_after is not None and self.swap_before is not None else None),
        }


def request_inference(endpoint, body, timeout, server_pid=None):
    endpoint = local_endpoint(endpoint)
    opener = build_opener(ProxyHandler({}), NoRedirect())
    request = Request(endpoint, data=json.dumps(body, ensure_ascii=False, allow_nan=False).encode("utf-8"),
                      headers={"Content-Type": "application/json"}, method="POST")
    start = time.monotonic()
    monitor = ServerMonitor(server_pid)
    result = {"status": "inference_error", "response_text": ""}
    with monitor:
        try:
            with opener.open(request, timeout=timeout) as response:
                data = response.read(MAX_SERVER_RESPONSE_BYTES + 1)
            if len(data) > MAX_SERVER_RESPONSE_BYTES:
                raise ValueError("server response exceeds bounded size")
            raw = data.decode("utf-8")
            payload = strict_json(raw)
            result["server_response"] = payload
            result["server_response_text"] = raw
            choices = payload.get("choices") if isinstance(payload, dict) else None
            if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
                raise ValueError("expected exactly one completion choice")
            choice = choices[0]
            content = choice.get("message", {}).get("content")
            finish = choice.get("finish_reason")
            if not isinstance(content, str) or finish not in ("stop", "length"):
                raise ValueError("missing text or unsupported completion finish reason")
            result["server_usage"] = payload.get("usage")
            result["server_timings"] = payload.get("timings")
            usage = payload.get("usage")
            image_tokens = payload.get("image_tokens")
            result["prepared_inputs"] = {"image_input": "anonymous PNG data URL",
                                         "server_prompt_tokens": usage.get("prompt_tokens") if isinstance(usage, dict) else None,
                                         "image_tokens": image_tokens,
                                         "image_token_count_verified": type(image_tokens) is int and image_tokens > 0}
            result.update(status="completed", response_text=content, generation={"finish_reason": finish})
        except (TimeoutError, socket.timeout) as error:
            result.update(status="timeout", error="socket_inactivity_timeout: " + type(error).__name__ + ": " + str(error))
        except HTTPError as error:
            result["error"] = f"HTTPError: {error.code}"
            result["server_error_body"] = error.read(MAX_SERVER_RESPONSE_BYTES).decode("utf-8", errors="replace")
        except URLError as error:
            result.update(status="timeout" if isinstance(error.reason, (TimeoutError, socket.timeout)) else "inference_error",
                          error=type(error).__name__ + ": " + str(error.reason))
        except (OSError, ValueError, TypeError, AttributeError) as error:
            result["error"] = type(error).__name__ + ": " + str(error)
    result["metrics"] = {"wall_seconds": time.monotonic() - start, **monitor.metrics}
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--mode", choices=("shared", "native"), required=True)
    parser.add_argument("--model-provenance", type=Path, required=True)
    parser.add_argument("--runtime-provenance", type=Path, required=True)
    parser.add_argument("--system-prompt", type=Path)
    parser.add_argument("--user-prompt", type=Path)
    parser.add_argument("--server-pid", type=int, required=True)
    parser.add_argument("--model-name", default="jarvisart")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--limit", type=int, help="Explicit pilot over the first N cases in fixed manifest order")
    args = parser.parse_args(argv)
    if args.output.exists() or args.output.resolve() == args.fixtures.resolve():
        parser.error("output must be a new, separate directory")
    if args.mode == "native" and (args.system_prompt is None or args.user_prompt is None):
        parser.error("native mode requires frozen --system-prompt and --user-prompt files")
    if args.mode == "shared" and (args.system_prompt is not None or args.user_prompt is not None):
        parser.error("shared mode uses only the unchanged common prompt")
    timeout = args.timeout if args.timeout is not None else (180 if args.mode == "shared" else 300)
    if not 1 <= timeout <= 600 or (args.server_pid is not None and args.server_pid <= 0):
        parser.error("invalid timeout or server PID")
    endpoint = local_endpoint(args.server_url)
    model = verify_provenance(args.model_provenance)
    runtime = verify_provenance(args.runtime_provenance)
    server_binding = verify_server_binding(args.server_pid, model, runtime, endpoint)
    manifest = read_json(args.fixtures / "expectations.json")
    schema = read_json(args.fixtures / "response.schema.json")
    cases = manifest["cases"]
    if not isinstance(cases, list) or not cases or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("fixture cases must have unique IDs")
    if args.limit is not None and not 1 <= args.limit <= len(cases):
        parser.error("pilot limit must be a non-empty prefix of the suite")
    selected = cases[:args.limit] if args.limit is not None else cases
    # Case IDs are used only for local result filenames, never model inputs.
    import re
    if any(not re.fullmatch(r"[A-Za-z0-9_-]+", case["id"]) for case in selected):
        raise ValueError("invalid fixture case ID")
    prompt = (common.common_prompt(manifest, schema) if args.mode == "shared"
              else args.user_prompt.read_text(encoding="utf-8"))
    system_prompt = args.system_prompt.read_text(encoding="utf-8") if args.system_prompt else None
    if not prompt.strip() or (system_prompt is not None and not system_prompt.strip()):
        raise ValueError("empty frozen prompt")
    with ThreadPoolExecutor(max_workers=3) as pool:
        prepared = list(pool.map(lambda case: common.prepare_case(case, args.fixtures, 1024), selected))
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "responses").mkdir()
    (args.output / "common-prompt.txt").write_text(prompt, encoding="utf-8")
    if system_prompt is not None:
        (args.output / "system-prompt.txt").write_text(system_prompt, encoding="utf-8")
    common.write_json(args.output / "response.schema.json", schema)
    if args.mode == "shared":
        common.write_json(args.output / "decoder.schema.json", common.grammar_schema(schema))
    common.write_json(args.output / "model-provenance.json", model)
    common.write_json(args.output / "runtime-provenance.json", runtime)
    (args.output / "requirements.freeze.txt").write_text(subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True))
    run = {"schema_version": 1, "started_at_utc": datetime.now(timezone.utc).isoformat(),
           "suite_id": manifest["suite_id"], "mode": args.mode, "model": model, "runtime": runtime,
           "server_endpoint": endpoint, "server_pid": args.server_pid, "server_binding": server_binding,
           "prompt_sha256": sha256(prompt.encode()).hexdigest(),
           "system_prompt_sha256": sha256(system_prompt.encode()).hexdigest() if system_prompt is not None else None,
           "runner_source_sha256": common.digest(Path(__file__)),
           "common_runner_source_sha256": common.digest(Path(__file__).with_name("run.py")),
           "expectations_sha256": common.digest(args.fixtures / "expectations.json"),
           "response_schema_sha256": common.digest(args.fixtures / "response.schema.json"),
           "selection": {"kind": "fixed_prefix_pilot" if args.limit is not None else "complete_suite",
                         "case_ids": [case["id"] for case in selected], "suite_size": len(cases)},
           "generation_config": {"seed": 0, "temperature": 0.0, "top_p": 1.0, "top_k": 0,
                                 "max_new_tokens": 768 if args.mode == "shared" else 2048,
                                 "constrained_decoding": args.mode == "shared", "cache_prompt": False,
                                 "id_slot": 0, "timeout_seconds": timeout, "timeout_kind": "socket_inactivity"},
           "preprocessing": {"long_edge": 1024, "filter": "PIL LANCZOS", "color": "explicit sRGB interpretation of untagged fixtures", "version": 1},
           "hardware": {"machine": platform.machine(), "os": platform.platform(), "macos": platform.mac_ver()[0]},
           "inference_parallelism": 1, "raster_preparation_parallelism": 3,
           "offline_inference": True, "cross_image_caches_requested": False,
           "render_status": "notRun", "shared_schema_evaluation": "pending" if args.mode == "shared" else "notApplicable",
           "limits": ["Server is externally started: process executable/model/mmproj paths match verified local file provenance.",
                      "cache_prompt=false requests fresh per-image state; actual server counters are retained when supplied.",
                      "Server-tree RSS may double-count shared mappings. OS available/swap are global, not attributable to this request.",
                      "No GPU allocator peak or verified OS-cold-cache measurement. No correction adapter executed.",
                      "HTTP timeout bounds socket inactivity, not total wall duration; token limits bound normal generation work.",
                      "Native mode uses a separate frozen prompt/output condition and does not pass the common JSON contract."]}
    common.write_json(args.output / "run.json", run)
    exit_code = 0
    try:
        for index, item in enumerate(prepared):
            body = make_request(item, prompt, args.mode, schema, system_prompt, args.model_name)
            result = request_inference(endpoint, body, timeout, args.server_pid)
            envelope = {key: value for key, value in item.items() if key != "pixels"}
            envelope.update(ordinal=index + 1, mode=args.mode, **result)
            common.write_json(args.output / "responses" / (item["case_id"] + ".json"), envelope)
            print(json.dumps({"case": item["case_id"], "status": result["status"],
                              "finish_reason": result.get("generation", {}).get("finish_reason"),
                              "seconds": result["metrics"]["wall_seconds"]}), flush=True)
            if result["status"] != "completed":
                # A timed-out HTTP request may still occupy the model slot. Do
                # not submit another image or silently retry in that state.
                exit_code = 1
                break
    except BaseException as error:
        run["runner_error"] = type(error).__name__ + ": " + str(error)
        exit_code = 1
    finally:
        run["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        run["exit_code"] = exit_code
        common.write_json(args.output / "run.json", run)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

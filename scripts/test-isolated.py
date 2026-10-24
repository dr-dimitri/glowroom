#!/usr/bin/env python3
"""Run the complete SDK-discovered catalog in fresh, ordered test processes."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
TEST_SCRIPT = ROOT / "scripts" / "test.sh"
PASSED_MARKER = re.compile(
    r"^\s*✔\s+Test run with \d+ tests?(?: in \d+ suites?)? passed after [^\r\n]+\.\s*$",
    re.MULTILINE,
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


class ValidationError(Exception):
    pass


@dataclass(frozen=True)
class Batch:
    name: str
    pattern: str
    test_ids: tuple[str, ...]


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_catalog(path: Path) -> list[str]:
    identifiers = path.read_text(encoding="utf-8").splitlines()
    if not identifiers:
        raise ValidationError("SDK discovery returned an empty test catalog")
    for identifier in identifiers:
        suite, separator, function = identifier.partition("/")
        if not separator or not function or "." not in suite or any(c.isspace() for c in suite):
            raise ValidationError(f"Unexpected SDK test identifier: {identifier!r}")
    duplicates = [name for name, count in Counter(identifiers).items() if count != 1]
    if duplicates:
        raise ValidationError(f"Duplicate SDK test identifiers: {duplicates}")
    return identifiers


def make_batches(identifiers: list[str]) -> list[Batch]:
    core = sorted(name for name in identifiers if name.startswith("GlowroomCoreTests."))
    suites: dict[str, list[str]] = defaultdict(list)
    for identifier in identifiers:
        if not identifier.startswith("GlowroomCoreTests."):
            suites[identifier.partition("/")[0]].append(identifier)
    batches = [Batch("GlowroomCoreTests", r"^GlowroomCoreTests\.", tuple(core))] if core else []
    # AppKit animations share process-wide resources even with --no-parallel.
    # Every non-Core suite gets a fresh process, including unfamiliar modules.
    batches.extend(Batch(suite, "^" + re.escape(suite) + "/", tuple(sorted(names)))
                   for suite, names in sorted(suites.items()))
    planned = Counter(name for batch in batches for name in batch.test_ids)
    if planned != Counter(identifiers):
        raise ValidationError("Batch partition does not cover the complete catalog exactly once")
    for batch in batches:
        selected = {name for name in identifiers if re.search(batch.pattern, name)}
        if selected != set(batch.test_ids):
            raise ValidationError(f"Batch filter differs from its planned identifiers: {batch.name}")
    return batches


def stop_process_group(process: subprocess.Popen) -> None:
    # start_new_session makes this exact PID the group owner. Never select or
    # signal processes by name, or touch another build/test's process group.
    previous = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            process.poll()  # Reap our direct child if it has already exited.
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def run_logged(arguments: list[str], output: Path, timeout: float,
               stderr: Path | None = None) -> dict:
    started = time.monotonic()
    with output.open("wb") as stdout:
        error_file = stderr.open("wb") if stderr is not None else None
        try:
            process = subprocess.Popen(arguments, cwd=ROOT, stdout=stdout,
                                       stderr=error_file if error_file is not None else subprocess.STDOUT,
                                       start_new_session=True)
            timed_out = False
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop_process_group(process)
            except KeyboardInterrupt:
                stop_process_group(process)
                raise
        finally:
            if error_file is not None:
                error_file.close()
    return {"exitCode": process.returncode, "timedOut": timed_out,
            "seconds": round(time.monotonic() - started, 3)}


def require_success(result: dict, description: str, log: Path) -> None:
    if result["timedOut"] or result["exitCode"] != 0:
        raise ValidationError(f"{description} failed: {result}; see {log}")


def canonical_xml_id(classname: str, name: str, planned: set[str]) -> str:
    identifier = f"{classname}/{name}"
    if identifier in planned:
        return identifier
    # A parameterized case may append an explicit argument decoration after
    # the complete declared signature. Never strip/rewrite that signature or
    # use a fuzzy function-name match: an unknown XML test must fail coverage.
    candidates = []
    for expected in planned:
        suite, _, function = expected.partition("/")
        if suite != classname or ":" not in function or not name.startswith(function):
            continue
        suffix = name[len(function):]
        if re.fullmatch(r"\s+(?:\[[^\r\n]*\]|\(arguments:\s*[^\r\n]*\))", suffix):
            candidates.append(expected)
    if len(candidates) == 1:
        return candidates[0]
    raise ValidationError(f"XML contains an unplanned or unsupported test case: {identifier!r}")


def validate_xml(path: Path, batch: Batch) -> dict:
    root = ET.parse(path).getroot()
    if root.tag not in {"testsuites", "testsuite"}:
        raise ValidationError(f"Unexpected xUnit root: {root.tag!r}")
    suites = list(root.iter("testsuite"))
    if not suites:
        raise ValidationError("xUnit contains no completed test suite")
    for node in [root] + suites:
        for attribute in ("errors", "failures"):
            value = node.get(attribute)
            if value is None and node.tag == "testsuites":
                continue
            if value is None or not value.isdecimal() or int(value) != 0:
                raise ValidationError(f"xUnit {attribute} is not explicitly zero: {value!r}")
    if any(node.tag in {"error", "failure"} for node in root.iter()):
        raise ValidationError("xUnit contains a failure/error element")
    for suite in suites:
        declared, skipped = suite.get("tests"), suite.get("skipped")
        if declared is None or not declared.isdecimal() or skipped is None or not skipped.isdecimal():
            raise ValidationError("xUnit suite has invalid tests/skipped counts")
        cases = list(suite.iter("testcase"))
        actual_skipped = sum(case.find("skipped") is not None for case in cases)
        # This SDK counts executed tests separately from skipped Trait cases.
        # Both remain in the catalog/XML coverage and neither may disappear.
        if int(skipped) != actual_skipped or int(declared) + int(skipped) != len(cases):
            raise ValidationError("xUnit executed/skipped counts differ from its complete test cases")
    cases = list(root.iter("testcase"))
    planned = set(batch.test_ids)
    observed = set()
    for case in cases:
        classname, name = case.get("classname"), case.get("name")
        if not classname or not name:
            raise ValidationError("xUnit test case is missing classname/name")
        observed.add(canonical_xml_id(classname, name, planned))
    if observed != planned:
        raise ValidationError(f"xUnit coverage mismatch; missing={sorted(planned - observed)}, "
                              f"unexpected={sorted(observed - planned)}")
    return {"verifiedTests": len(observed), "xmlTestCases": len(cases),
            "xmlSkippedCases": sum(case.find("skipped") is not None for case in cases)}


def validate_batch(log: Path, xml: Path, batch: Batch, result: dict) -> dict:
    require_success(result, batch.name, log)
    text = ANSI_ESCAPE.sub("", log.read_text(encoding="utf-8", errors="replace"))
    if not PASSED_MARKER.search(text):
        raise ValidationError("Missing regular Swift Testing test-run completion marker")
    return validate_xml(xml, batch)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Reuse the existing complete test build")
    parser.add_argument("--report-directory", type=Path, help="New, nonexistent report directory")
    parser.add_argument("--timeout", type=float, default=600, help="Seconds per subprocess (default: 600)")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite positive number")
    return args


def main() -> int:
    args = arguments()
    try:
        if args.report_directory is None:
            report = Path(tempfile.mkdtemp(prefix="Glowroom-Isolated-Tests-"))
        else:
            report = args.report_directory.expanduser().resolve()
            report.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        print(f"Cannot create fresh report directory: {error}", file=sys.stderr)
        return 2
    summary = {"schemaVersion": 1, "startedAt": datetime.now(timezone.utc).isoformat(),
               "packagePath": str(ROOT), "reportDirectory": str(report),
               "skipBuild": args.skip_build, "timeoutSeconds": args.timeout,
               "status": "running", "batches": []}
    summary_path = report / "summary.json"
    write_json(summary_path, summary)
    print(f"Reports: {report}", flush=True)
    try:
        if not args.skip_build:
            print("Compile complete test targets once (jobs=3, no matching test execution)", flush=True)
            log = report / "compile.log"
            result = run_logged([str(TEST_SCRIPT), "--jobs", "3", "--no-parallel", "--filter", "^$"], log, args.timeout)
            summary["compile"] = result
            require_success(result, "Test compilation", log)
        catalog = report / "catalog.txt"
        result = run_logged([str(TEST_SCRIPT), "list", "--skip-build"], catalog, args.timeout,
                            stderr=report / "list.stderr.log")
        summary["discovery"] = result
        require_success(result, "SDK discovery", report / "list.stderr.log")
        identifiers = load_catalog(catalog)
        batches = make_batches(identifiers)
        summary.update(catalogTests=len(identifiers), catalogSuites=len({name.partition("/")[0] for name in identifiers}),
                       plannedBatches=len(batches))
        write_json(report / "plan.json", [{"name": batch.name, "filter": batch.pattern, "testIDs": batch.test_ids}
                                           for batch in batches])
        write_json(summary_path, summary)
        for index, batch in enumerate(batches, 1):
            prefix = f"batch-{index:03d}"
            log = report / f"{prefix}.log"
            error_log = report / f"{prefix}.stderr.log"
            xml = report / f"{prefix}.xml"
            entry = {"name": batch.name, "filter": batch.pattern, "plannedTests": len(batch.test_ids),
                     "log": str(log), "stderrLog": str(error_log), "xml": str(xml), "status": "running"}
            summary["batches"].append(entry)
            write_json(summary_path, summary)
            print(f"[{index}/{len(batches)}] {batch.name} ({len(batch.test_ids)} tests)", end=" ... ", flush=True)
            result = run_logged([str(TEST_SCRIPT), "--skip-build", "--no-parallel", "--filter", batch.pattern,
                                 "--xunit-output", str(xml)], log, args.timeout, stderr=error_log)
            entry.update(result)
            try:
                entry.update(validate_batch(log, xml, batch, result))
                entry["status"] = "passed"
            except (ValidationError, OSError, ET.ParseError) as error:
                entry.update(status="failed", error=str(error))
            print(f"{entry['status'].upper()} ({result['seconds']:.3f}s)", flush=True)
            write_json(summary_path, summary)
        summary["verifiedTests"] = sum(entry.get("verifiedTests", 0) for entry in summary["batches"])
        passed = all(entry["status"] == "passed" for entry in summary["batches"])
        summary["status"] = "passed" if passed and summary["verifiedTests"] == len(identifiers) else "failed"
    except KeyboardInterrupt:
        summary.update(status="interrupted", error="Interrupted; active subprocess group terminated and reaped")
    except (ValidationError, OSError, ET.ParseError) as error:
        summary.update(status="failed", error=str(error))
    summary["finishedAt"] = datetime.now(timezone.utc).isoformat()
    write_json(summary_path, summary)
    failed = [entry["name"] for entry in summary["batches"] if entry["status"] != "passed"]
    print(f"{summary['status'].upper()}: {summary.get('verifiedTests', 0)}/{summary.get('catalogTests', 0)} "
          f"verified tests; {len(failed)} unsuccessful batches. Summary: {summary_path}", flush=True)
    if "error" in summary:
        print(summary["error"], file=sys.stderr)
    return 0 if summary["status"] == "passed" else 130 if summary["status"] == "interrupted" else 1


if __name__ == "__main__":
    def interrupt(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    sys.exit(main())

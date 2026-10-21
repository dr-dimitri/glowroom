#!/usr/bin/env python3
"""Summarize mask/preview JSONL without mixing files, sizes or cache states.

Warmup sequences are excluded. The first renderer sample is retained in a
separate preview group, so it cannot distort the initialized-renderer group.
The median interpolates even samples; p95 uses nearest rank, matching Swift.
Only Python's standard library is required; .jsonl.gz inputs are supported.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass, field
import gzip
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any


KEYS = ["file", "scenario", "fixture", "workload", "backend", "cache", "state",
        "width", "height", "output_width", "output_height"]
METRICS = ["n", "p50_ms", "p95_ms", "min_ms", "max_ms", "requests_per_second",
           "canvas_megapixels_per_second", "cpu_p50_ms", "cpu_p95_ms", "peak_rss_bytes"]


@dataclass
class Group:
    wall: list[float] = field(default_factory=list)
    cpu: list[float] = field(default_factory=list)
    rss: int = 0
    phases: dict[str, list[float]] = field(default_factory=dict)


def p95(values: list[float]) -> float:
    return sorted(values)[max(0, math.ceil(0.95 * len(values)) - 1)]


def number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def rounded_dimension(value: float) -> int:
    # Swift .rounded() is away from zero at positive halfway values.
    return max(1, math.floor(value + 0.5))


def accumulate(path: Path, groups: dict[tuple[str, ...], Group]) -> None:
    metadata: dict[str, Any] = {}
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error.msg}") from error
            if not isinstance(record, dict):
                raise ValueError(f"{path}:{line_number}: expected JSON object")
            if record.get("event") == "metadata":
                metadata = record
                continue
            kind = record.get("kind")
            event = record.get("event")
            if event != "sample" and kind not in ("local-mask-sample", "preview-sample"):
                continue
            if record.get("warmup", False):
                continue

            def invalid(message: str) -> ValueError:
                return ValueError(f"{path}:{line_number}: {message}")

            def dimension(value: Any, name: str) -> int | str:
                if value == "":
                    return ""
                if type(value) is not int or value <= 0:
                    raise invalid(f"{name} must be a positive integer")
                return value

            raw_phases = record.get("phases_ms", {})
            if not isinstance(raw_phases, dict):
                raise invalid("phases_ms must be an object")
            phases = dict(raw_phases)
            width = record.get("width", metadata.get("width", ""))
            height = record.get("height", metadata.get("height", ""))
            output_width, output_height = width, height
            state = "measured"
            if event == "sample":
                scenario = "canonical-mask"
                elapsed = record.get("wall_ms")
                width, height = dimension(width, "width"), dimension(height, "height")
                if width and height:
                    maximum = dimension(metadata.get("overlay_max_dimension", 1_600), "overlay_max_dimension")
                    if not maximum:
                        raise invalid("overlay_max_dimension must be a positive integer")
                    scale = min(1, maximum / max(width, height))
                    output_width = rounded_dimension(width * scale)
                    output_height = rounded_dimension(height * scale)
            elif kind == "local-mask-sample":
                scenario = "local-mask"
                elapsed = record.get("total_ms")
                width, height = record.get("canvas_width", ""), record.get("canvas_height", "")
                output_width, output_height = record.get("output_width", ""), record.get("output_height", "")
                for phase in ["graph", "render"]:
                    value = record.get(phase + "_ms")
                    if number(value):
                        phases[phase] = value
            elif kind == "preview-sample":
                scenario = "preview"
                elapsed = record.get("total_ms")
                state = "first-process-renderer" if record.get("fresh_renderer") else "initialized"
            else:
                continue
            width, height = dimension(width, "width"), dimension(height, "height")
            output_width = dimension(output_width, "output_width")
            output_height = dimension(output_height, "output_height")
            if not number(elapsed) or elapsed < 0:
                raise ValueError(f"{path}:{line_number}: sample requires nonnegative finite wall/total_ms")
            identifiers = [str(path), scenario, record.get("fixture", ""), record.get("workload", ""),
                           record.get("backend", ""), record.get("cache", ""), state,
                           width, height, output_width, output_height]
            key = tuple(str(value) for value in identifiers)
            group = groups.setdefault(key, Group())
            group.wall.append(float(elapsed))
            cpu = record.get("cpu_ms")
            if cpu is not None:
                if not number(cpu) or cpu < 0:
                    raise invalid("cpu_ms must be nonnegative and finite")
                group.cpu.append(float(cpu))
            rss = record.get("peak_rss_bytes")
            if rss is not None:
                if type(rss) is not int or rss < 0:
                    raise invalid("peak_rss_bytes must be a nonnegative integer")
                group.rss = max(group.rss, int(rss))
            for phase, value in phases.items():
                if not number(value) or value < 0:
                    raise invalid(f"phase {phase} must be nonnegative and finite")
                group.phases.setdefault(str(phase), []).append(float(value))


def summarize(paths: list[Path], destination: Any) -> None:
    groups: dict[tuple[str, ...], Group] = {}
    for path in paths:
        accumulate(path, groups)
    phase_names = sorted({phase for group in groups.values() for phase in group.phases})
    writer = csv.DictWriter(destination, fieldnames=KEYS + METRICS + [f"phase_{name}_p50_ms" for name in phase_names],
                            lineterminator="\n")
    writer.writeheader()
    for key, group in sorted(groups.items()):
        row: dict[str, Any] = dict(zip(KEYS, key))
        total = sum(group.wall)
        row.update(n=len(group.wall), p50_ms=statistics.median(group.wall), p95_ms=p95(group.wall),
                   min_ms=min(group.wall), max_ms=max(group.wall), peak_rss_bytes=group.rss)
        if total > 0:
            row["requests_per_second"] = 1_000 * len(group.wall) / total
            if row["width"] and row["height"]:
                row["canvas_megapixels_per_second"] = len(group.wall) * int(row["width"]) * int(row["height"]) / total / 1_000
        if group.cpu:
            row["cpu_p50_ms"], row["cpu_p95_ms"] = statistics.median(group.cpu), p95(group.cpu)
        for phase, values in group.phases.items():
            row[f"phase_{phase}_p50_ms"] = statistics.median(values)
        writer.writerow({name: f"{value:.6f}" if isinstance(value, float) else value for name, value in row.items()})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path, nargs="+", help="JSONL or gzip-compressed JSONL metric files")
    parser.add_argument("--output", "-o", type=Path, help="CSV destination; default stdout")
    options = parser.parse_args()
    try:
        if options.output:
            if options.output.resolve() in {path.resolve() for path in options.inputs} or (
                options.output.exists() and any(options.output.samefile(path) for path in options.inputs)
            ):
                raise ValueError("CSV output must differ from every raw input file")
            with options.output.open("w", encoding="utf-8", newline="") as destination:
                summarize(options.inputs, destination)
        else:
            summarize(options.inputs, sys.stdout)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()

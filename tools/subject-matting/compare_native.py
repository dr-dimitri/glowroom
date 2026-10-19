#!/usr/bin/env python3
"""Compare each standalone native prediction against a saved local reference."""
import argparse
import json
from pathlib import Path
import numpy as np

from validation import compare

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--reference", type=Path, required=True)
parser.add_argument("--native", type=Path, required=True, help="Directory emitted by benchmark.swift")
args = parser.parse_args()
benchmark = json.loads((args.native / "benchmark.json").read_text())
side = benchmark["side"]
reference = np.load(args.reference)
paths = sorted(args.native.glob("alpha-*.f32"))
if len(paths) != len(benchmark["inferenceSeconds"]):
    raise SystemExit("Missing per-prediction alpha: rerun updated benchmark.swift")
metrics = {}
for path in paths:
    actual = np.fromfile(path, dtype=np.float32).reshape(1, 1, side, side)
    metrics[path.name] = compare(reference, actual, shape=(1, 1, side, side), coverage=True,
                                 mean_limit=0.01, p99_limit=0.1)
print(json.dumps(metrics, indent=2))

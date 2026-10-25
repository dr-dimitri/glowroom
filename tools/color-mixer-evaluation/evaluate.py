"""Run both native candidates against the fixed independent scalar oracle."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
from reference import BANDS, input_pixel, reference_pixel

ROOT = Path(__file__).resolve().parent
TOLERANCE = .0001


def summarize(fixtures, native, version):
    if native["version"] != version or native["fixtureCount"] != len(fixtures["fixtures"]):
        raise ValueError("native candidate/fixture identity mismatch")
    cases = fixtures["settings"]
    records = native["records"]
    if len(records) != len(cases) or [x["settings"] for x in records] != [x["id"] for x in cases]:
        raise ValueError("missing, duplicate, or reordered native result")
    summaries, failures = [], []
    for case, record in zip(cases, records):
        pixels = record["pixels"]
        if len(pixels) != 4 * len(fixtures["fixtures"]):
            raise ValueError("incomplete native pixel raster")
        settings = dict(case["value"], version=version)
        groups = {}
        finite = True
        alpha_error = neutral_error = gray_error = orange_error = 0.
        for i, fixture in enumerate(fixtures["fixtures"]):
            actual = pixels[i * 4:i * 4 + 4]
            if any(type(x) not in (int, float) or not math.isfinite(x) for x in actual):
                finite = False
                failures.append({"settings": case["id"], "fixture": fixture["id"], "reason": "nonfinite native RGBAf"})
                continue
            expected = reference_pixel(fixture["rgba"], settings)
            alpha_error = max(alpha_error, abs(actual[3] - expected[3]))
            if actual[3] == 0:
                error = max(abs(x) for x in actual)
            else:
                error = max(abs(actual[c] / actual[3] - expected[c]) for c in range(3))
            group = fixture["group"]
            previous = groups.get(group)
            if previous is None or error > previous["maximumLinearRGBError"]:
                groups[group] = {"maximumLinearRGBError": error, "worstFixture": fixture["id"]}
            source = input_pixel(fixture["rgba"])
            identity_error = max(abs(actual[c] - source[c]) for c in range(4))
            if case["kind"] == "neutral":
                neutral_error = max(neutral_error, identity_error)
            if fixture["group"] == "gray":
                gray_error = max(gray_error, identity_error)
            if case["id"] == "blue-moderate" and fixture["id"].startswith("patch-orange"):
                orange_error = max(orange_error, identity_error)
            if case["kind"] == "moderate" and error > TOLERANCE:
                failures.append({"settings": case["id"], "fixture": fixture["id"],
                                 "reason": "linear RGB error exceeds fixed gate", "error": error})
        for label, error in (("alpha", alpha_error), ("neutral identity", neutral_error),
                             ("gray identity", gray_error), ("orange isolation", orange_error)):
            if error != 0:
                failures.append({"settings": case["id"], "reason": label, "error": error})
        summaries.append({"settings": case["id"], "kind": case["kind"], "finite": finite,
                          "alphaError": alpha_error, "neutralIdentityError": neutral_error,
                          "grayIdentityError": gray_error, "orangeIsolationError": orange_error,
                          "groups": groups})
    return {"candidateVersion": version, "backend": native["backend"], "os": native["os"],
            "fixtureCount": len(fixtures["fixtures"]), "settingsCount": len(cases),
            "linearRGBTolerance": TOLERANCE, "numericalDecision": "no-go" if failures else "pass",
            "productionDecision": "no-go" if failures else "blocked", "failureCount": len(failures),
            "failures": failures, "summaries": summaries,
            "missingProductionEvidence": [
                "Natural-photo and saturated P3 visual acceptance, including banding and hue fringes",
                "Product integration, persistence/backup/undo and stale-result acceptance",
                "Native 1000 x 660, keyboard and VoiceOver acceptance"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fixture_bytes = (ROOT / "fixtures.json").read_bytes()
    fixtures = json.loads(fixture_bytes)
    candidates = []
    # Two dependent evaluations share one small admitted raster. No workers per
    # band/channel: CPU orchestration is tiny and serial; Core Image schedules
    # the data-parallel Float pixel graph on its supported native backend.
    with tempfile.TemporaryDirectory(prefix="glowroom-color-mixer-") as temporary:
        for version in (1, 2):
            output = Path(temporary) / f"native-v{version}.json"
            subprocess.run(["xcrun", "swift", str(ROOT / "ColorMixerCandidate.swift"),
                            str(ROOT / "fixtures.json"), str(output), str(version)], check=True)
            candidates.append(summarize(fixtures, json.loads(output.read_text()), version))
    result = {"schemaVersion": 1, "fixtureSHA256": hashlib.sha256(fixture_bytes).hexdigest(),
              # An explicitly versioned successor may qualify independently
              # of the failed original. Missing visual/product evidence still
              # keeps a numerically successful latest candidate blocked.
              "productionDecision": candidates[-1]["productionDecision"],
              "candidates": candidates}
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(f"Color mixer: {result['productionDecision']}; report: {args.output}")


if __name__ == "__main__":
    main()

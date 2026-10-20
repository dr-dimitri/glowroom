#!/usr/bin/env python3
"""Model-free CLI regression using archived LaMa outputs as transport fixtures.

The fabricated SDXL metadata is ONLY a replay routing test. It is not evidence
of SDXL inference, model quality, timing, memory use, or product capability.
This script never builds, downloads, converts, or invokes an inference mode.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


CASES = ["01-structured-removal-hard", "warm-1", "warm-2", "warm-3"]
FILES = ["source.png", "raw.png", "replace-mask.png"]
DISCLAIMER = ("Synthetic SDXL metadata around existing real LaMa V2 PNGs; "
              "CLI/compositor routing regression only; no SDXL inference or quality evidence")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True,
                        help="already built image-generation developer executable; never built by this probe")
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--archive", type=Path, required=True,
                        help="external LaMa V2 archive containing native/artifacts and compositor report")
    parser.add_argument("--output-parent", type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    repository = args.repository.resolve(strict=True)
    original = args.archive.resolve(strict=True)
    require(original != repository and repository not in original.parents,
            "--archive must be outside the repository")
    require((original / "native/artifacts").is_dir() and
            (original / "compositor/current-compositor-report.json").is_file(),
            "--archive must contain native/artifacts and compositor/current-compositor-report.json")
    artifacts = original / "native/artifacts"
    golden = {case["caseID"]: case for case in
              json.loads((original / "compositor/current-compositor-report.json").read_text())["cases"]}
    root = Path(tempfile.mkdtemp(prefix="picedit-sdxl-cli-replay-probe-", dir=args.output_parent))
    report = {"schemaVersion": 1, "purpose": DISCLAIMER, "inferenceExecuted": False,
              "binary": str(binary), "binarySHA256": digest(binary),
              "source": str(original), "sourceModel": "archived LaMa Core ML V2",
              "metadataModel": "synthetic SDXL replay metadata only",
              "root": str(root), "probes": []}
    write_json(root / "probe-report.json", report)

    def metadata(ids, version=1):
        return {"schemaVersion": 1, "preprocessingVersion": version,
                "purpose": DISCLAIMER, "inferenceExecuted": False,
                "runs": [{"id": case_id} for case_id in ids]}

    def make_input(name, ids, value):
        destination = root / name
        destination.mkdir(mode=0o700)
        for case_id in ids:
            folder = destination / "artifacts" / case_id
            folder.mkdir(parents=True)
            for filename in FILES:
                shutil.copyfile(artifacts / case_id / filename, folder / filename)
        write_json(destination / "sdxl-report.json", value)
        write_json(destination / "transport-provenance.json", {
            "purpose": DISCLAIMER, "inferenceExecuted": False,
            "originalHashes": {case_id: {filename: digest(artifacts / case_id / filename)
                                        for filename in FILES} for case_id in ids}})
        return destination

    def execute(name, source, error=None):
        output = root / (name + "-compositor")
        command = [str(binary), "replay", "--historical", str(source), "--out", str(output)]
        require("--run" not in command, "The replay probe must not opt into model work")
        stdout, stderr = root / (name + ".stdout"), root / (name + ".stderr")
        with stdout.open("wb") as out, stderr.open("wb") as err:
            result = subprocess.run(command, cwd=repository, stdin=subprocess.DEVNULL,
                                    stdout=out, stderr=err, timeout=120, check=False)
        entry = {"name": name, "command": command, "returnCode": result.returncode,
                 "expectedError": error, "stdout": stdout.name, "stderr": stderr.name}
        report["probes"].append(entry)
        write_json(root / "probe-report.json", report)
        if error is not None:
            text = stdout.read_text(errors="replace") + stderr.read_text(errors="replace")
            require(result.returncode != 0, name + " unexpectedly succeeded")
            require(error in text, name + " failed for a different reason")
            require(not output.exists(), name + " wrote replay output before rejecting metadata")
            entry["passed"] = True
            return None
        require(result.returncode == 0, name + " failed; inspect retained logs")
        return json.loads((output / "current-compositor-report.json").read_text())

    try:
        # Missing distinct cases 02..06 are deliberate: this must use runs IDs.
        source = make_input("four-cases", CASES, metadata(CASES))
        replay = execute("four-cases", source)
        require([case["caseID"] for case in replay["cases"]] == CASES,
                "Standalone replay did not preserve exactly the four recorded IDs in order")
        for case in replay["cases"]:
            require(case["outsideRGBABytesChanged"] == 0, "Four-case replay altered preserved pixels")
            require(case["finalRGBA8SHA256"] == golden[case["caseID"]]["finalRGBA8SHA256"],
                    "Replay pixels differ from the archived real LaMa compositor result")
            for filename in FILES:
                require(digest(root / "four-cases-compositor" / case["caseID"] / filename) ==
                        digest(artifacts / case["caseID"] / filename), "Replay changed raw transport inputs")
        report["probes"][-1]["passed"] = True
        report["probes"][-1]["caseIDs"] = CASES

        # Opaque 01/warm cases cannot distinguish the alpha policy. A separate
        # real partial-alpha LaMa result makes the selected policy observable.
        alpha_id = "04-partial-alpha-hard"
        source = make_input("alpha-policy", [alpha_id], metadata([alpha_id]))
        replay = execute("alpha-policy", source)
        require(len(replay["cases"]) == 1, "Alpha probe must replay exactly one case")
        case = replay["cases"][0]
        require(case["caseID"] == alpha_id and case["alphaPolicy"].startswith("Straight RGB model input/output"),
                "SDXL replay did not select the straight-RGB interpretation")
        require(case["sourceAlphaBytesChanged"] == 0 and case["outsideRGBABytesChanged"] == 0,
                "Alpha probe altered source alpha or preserved pixels")
        require(case["finalRGBA8SHA256"] == golden[alpha_id]["finalRGBA8SHA256"],
                "Alpha replay pixels differ from the archived LaMa result")
        report["probes"][-1]["passed"] = True
        report["probes"][-1]["observedAlphaPolicy"] = case["alphaPolicy"]

        invalid = [
            ("unknown-version", metadata(CASES, version=999), "unsupported-sdxl-preprocessing-version"),
            ("duplicate-id", metadata([CASES[0], CASES[0]]), "invalid-sdxl-replay-runs"),
            ("missing-id", {**metadata(CASES), "runs": [{"id": CASES[0]}, {}]}, "invalid-sdxl-replay-runs"),
            ("empty-runs", metadata([]), "invalid-sdxl-replay-runs"),
            ("missing-runs", {"preprocessingVersion": 1, "purpose": DISCLAIMER}, "invalid-sdxl-replay-runs"),
        ]
        for name, value, error in invalid:
            source = make_input(name, CASES, value)
            execute(name, source, error=error)
        report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["failure"] = str(error)
        raise
    finally:
        write_json(root / "probe-report.json", report)
        print("Model-free replay probe report:", root / "probe-report.json", flush=True)
    print("PASS: exactly four recorded IDs, observable straight RGB, and five malformed-metadata rejections")


if __name__ == "__main__":
    main()

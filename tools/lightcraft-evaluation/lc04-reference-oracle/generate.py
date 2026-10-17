#!/usr/bin/env python3
"""Verify LC-04 Float32 vectors against pinned original Lightcraft Rust bodies.

Regeneration only: Python, rustc and a local Lightcraft checkout. Normal Swift
tests read vectors.json and have no Rust dependency. The checkout is read only.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import subprocess
import tempfile

COMMON = pathlib.Path(__file__).parents[1] / "lc03-reference-oracle/generate.py"
SPEC = importlib.util.spec_from_file_location("lc03_oracle", COMMON)
LC03 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LC03)
COMMIT = LC03.COMMIT
SOURCES = dict(LC03.SOURCES, **{
    "crates/pipeline/src/finish.rs": "1ae53438884cbad585f7488f08a12edac5156432df26036c9840cb89d4d2a19b",
    "crates/color/src/lib.rs": "167ea499069e9dda021d4a4b6e0c196ea75abbea33da08dbaa0f91e4071cc4b2",
    "crates/pipeline/src/tone.rs": "a0a477de88b3e74d8b622586fc674f727c62e66eda188ed5845dfcbef06d227e",
})


def constant(source, name):
    result = re.search(r"^pub const " + name + r"\b[^\n]*;", source, re.MULTILINE)
    if not result:
        raise ValueError(f"Missing original constant: {name}")
    return result[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=pathlib.Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    sources = {}
    for path, expected in SOURCES.items():
        # git show reads exactly the pin, including when the user's checkout is
        # on another branch, without switching or changing any local files.
        data = subprocess.check_output(["git", "-C", str(args.checkout), "show", f"{COMMIT}:{path}"])
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit(f"Source hash mismatch: {path}")
        sources[pathlib.Path(path).stem] = data.decode()
    modules = "\n".join("mod " + name + " {\n" + sources[name].split("#[cfg(test)]")[0] + "\n}"
                        for name in ("resample", "blur"))
    local = "extern crate self as lightcraft_raster;\nuse blur::gaussian;\n"
    local += "\n".join(LC03.function(sources["local"], name)
                       for name in ["guided", "guided_coeffs", "guided_apply", "guided_fast", "guided_fast_step", "log_lum"])
    local += "\n" + constant(sources["local"], "CLARITY_EPS")
    local += "\n" + constant(sources["lib"], "LUMA_2020")
    local += "\n" + LC03.function(sources["lib"], "luminance_2020")
    local += "\nmod tone {" + constant(sources["tone"], "GREY") + "}\n"
    local += LC03.function(sources["finish"], "smooth")
    finish = sources["finish"]
    start = finish.index("let det = (l_pre - b.data[i]).clamp(-2.5, 2.5);")
    end = finish.index("delta += cl * 0.85 * det * (0.35 + 0.65 * mid);", start)
    clarity = finish[start:end + len("delta += cl * 0.85 * det * (0.35 + 0.65 * mid);")]
    start = finish.index("let det = l_pre - b.data[i];", end)
    end = finish.index("delta += tx * 1.1 * det.clamp(-1.0, 1.0) * tame;", start)
    texture = finish[start:end + len("delta += tx * 1.1 * det.clamp(-1.0, 1.0) * tame;")]
    # Both snippets are unchanged original statements. Only the surrounding
    # isolated per-pixel inputs and output storage are supplied here.
    local += "\nfn apply(p: &Plane, b: &Plane, strength: f32, clarity: bool) -> Plane {\n"
    local += "let log = p.map(|v| log_lum([v,v,v]));\nPlane::from_fn(p.width, p.height, |x,y| {\n"
    local += "let i=y*p.width+x; let l_pre=log.data[i]; let base=l_pre; let cl=strength; let tx=strength; let mut delta=0.0f32;\n"
    local += "if clarity {\n" + clarity + "\n} else {\n" + texture + "\n}\np.data[i] * delta.exp2()\n})\n}\n"
    cases = [(variant, 13, 9, sigma, strength)
             for variant, sigma in [("clarityGuidedLog", 1.2), ("clarityGuidedLog", 18.0),
                                    ("textureGaussianLogTamed", 0.6), ("textureGaussianLogTamed", 2.7)]
             for strength in [-0.7, 0.0, 0.7]]
    program = ["fn main() {"]
    for variant, width, height, sigma, strength in cases:
        program.append(f"let p = Plane::from_fn({width}, {height}, |x,y| "
                       "{ let v = if x < 6 { 0.0002f32 } else { 1.2f32 }; "
                       "v * (1.0 + (((x*31+y*17)%11) as f32 - 5.0)*0.07) });")
        program.append("let log=p.map(|v| log_lum([v,v,v]));")
        expression = f"guided_fast(&log,{sigma}f32,CLARITY_EPS)" if variant == "clarityGuidedLog" else f"gaussian(&log,{sigma}f32)"
        program.append("let b=" + expression + ";")
        program.append(f"let output=apply(&p,&b,{strength}f32,{str(variant == 'clarityGuidedLog').lower()});")
        program.append('println!("{:?}",p.data); println!("{:?}",log.data); println!("{:?}",b.data); println!("{:?}",output.data);')
    program.append("}")
    with tempfile.TemporaryDirectory(prefix="picedit-lc04-oracle-") as directory:
        root = pathlib.Path(directory)
        source = root / "oracle.rs"
        source.write_text(LC03.SHELL + modules + local + "\n".join(program))
        subprocess.run(["rustc", "--edition=2024", "-O", str(source), "-o", str(root / "oracle")], check=True)
        lines = subprocess.check_output([str(root / "oracle")], text=True).splitlines()
    records = []
    for index, (variant, width, height, sigma, strength) in enumerate(cases):
        records.append(dict(variant=variant, width=width, height=height, sigma=sigma, strength=strength,
                            input=json.loads(lines[index*4]), signal=json.loads(lines[index*4+1]),
                            base=json.loads(lines[index*4+2]), output=json.loads(lines[index*4+3])))
    result = dict(schema_version=1, upstream_commit=COMMIT, source_sha256=SOURCES,
                  generator="Original Rust filter functions and unchanged finish clarity/texture statements; LC-03 std-only storage shim",
                  absolute_float_tolerance=0.000005, cases=records)
    target = pathlib.Path(__file__).with_name("vectors.json")
    if args.write:
        target.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Wrote {len(records)} pinned upstream detail cases")
    elif json.loads(target.read_text()) != result:
        raise SystemExit("Pinned oracle does not reproduce vectors.json; inspect before --write")
    else:
        print(f"Verified {len(records)} pinned upstream detail cases")


if __name__ == "__main__":
    main()

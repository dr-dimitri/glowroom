#!/usr/bin/env python3
"""Regenerate LC-06 vectors with pinned original Rust NR functions, without Cargo.

Only optional regeneration needs rustc and a local Lightcraft checkout. Normal
Swift tests consume the committed JSON and add no Rust application dependency.
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
    "crates/color/src/lib.rs": "167ea499069e9dda021d4a4b6e0c196ea75abbea33da08dbaa0f91e4071cc4b2",
    "crates/pipeline/src/tone.rs": "a0a477de88b3e74d8b622586fc674f727c62e66eda188ed5845dfcbef06d227e",
})


def constant(source, name):
    match = re.search(r"^(?:pub )?const " + name + r"\b[^\n]*;", source, re.MULTILINE)
    if not match:
        raise ValueError(f"Missing original constant: {name}")
    return match[0]


def structure(source, name):
    match = re.search(r"^pub struct " + name + r"\b[^}]+}", source, re.MULTILINE)
    if not match:
        raise ValueError(f"Missing original structure: {name}")
    return "#[derive(Clone, Copy, Debug)]\n" + match[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=pathlib.Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    sources = {}
    for path, expected in SOURCES.items():
        data = subprocess.check_output(["git", "-C", str(args.checkout), "show", f"{COMMIT}:{path}"])
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit(f"Source hash mismatch: {path}")
        sources[pathlib.Path(path).stem] = data.decode()
    modules = "\n".join("mod " + name + " {\n" + sources[name].split("#[cfg(test)]")[0] + "\n}"
                        for name in ("resample", "blur"))
    shell = LC03.SHELL + """
pub type Rgb32f = Image<[f32; 3]>;
struct Detail { nr_luminance: f64, nr_color: f64, nr_detail: f64, nr_color_detail: f64, nr_color_smoothness: f64 }
pub struct DevelopSettings { detail: Detail }
fn profiling() -> bool { false }
"""
    local = "extern crate self as lightcraft_raster;\nuse blur::gaussian;\n"
    local += "\n".join(structure(sources["local"], name) for name in ["NrLum", "NrColor"])
    local += "\n" + "\n".join(constant(sources["local"], name) for name in ["NR_MIN_SIGMA", "NR_MIN_BLEND"])
    local += "\n" + "\n".join(LC03.function(sources["local"], name) for name in
                               ["detail_scale", "nr_radius", "nr_params", "apply_nr", "log_lum", "guided", "guided_coeffs", "guided_apply"])
    local += "\n" + constant(sources["lib"], "LUMA_2020") + "\n" + LC03.function(sources["lib"], "luminance_2020")
    local += "\nmod tone {" + constant(sources["tone"], "GREY") + "}\n"
    cases = [(control, 13, 9, amount, scale, "mixed")
             for control in ["luminance", "chroma"]
             for amount in [0.0, 20.0, 60.0, 100.0]
             for scale in [1.0, 0.5, 0.125, 0.02]]
    cases += [(control, width, height, 60.0, 1.0, pattern)
              for control in ["luminance", "chroma"]
              for width, height, pattern in [(4, 35, "mixed"), (1, 1, "negative"), (1, 7, "mixed"), (7, 1, "mixed")]]
    program = ["fn main() {"]
    for control, width, height, amount, scale, pattern in cases:
        lum, col = (amount, 0.0) if control == "luminance" else (0.0, amount)
        expression = "[-0.2f32,-0.1,-0.05]" if pattern == "negative" else """{
          let n = (((x*31+y*17)%13) as f32-6.0)*0.012;
          match x%7 {
            0 => [0.00001+n.abs()*0.01,0.00002,0.00003],
            1 => [0.18+n,0.18+n,0.18+n],
            2 => [0.7+n,0.08,0.03],
            3 => [-0.04,0.25+n,0.8],
            4 => [1.4+n,0.8,0.3],
            5 => [0.05,0.06+n,0.7],
            _ => [0.0,0.0,0.0]
          }
        }"""
        program.append(f"let mut p=Rgb32f::from_fn({width},{height},|x,y| {expression});")
        program.append(f"let settings=DevelopSettings{{detail:Detail{{nr_luminance:{lum},nr_color:{col},nr_detail:50.0,nr_color_detail:50.0,nr_color_smoothness:50.0}}}};")
        program.append(f"let scale=detail_scale({scale}f64*6000.0,6000); let (l,c)=nr_params(&settings,scale);")
        program.append('println!("{:?}",p.data);')
        program.append('println!("{:?}", if let Some(n)=l { vec![n.sigma,n.eps,n.k] } else if let Some(n)=c { vec![n.sigma,0.0,n.t] } else { vec![0.0,0.0,0.0] });')
        program.append('apply_nr(&mut p,l,c); println!("{:?}",p.data);')
    program.append("}")
    with tempfile.TemporaryDirectory(prefix="picedit-lc06-oracle-") as directory:
        root = pathlib.Path(directory)
        source = root / "oracle.rs"
        source.write_text(shell + modules + local + "\n".join(program))
        subprocess.run(["rustc", "--edition=2024", "-O", str(source), "-o", str(root / "oracle")], check=True)
        lines = subprocess.check_output([str(root / "oracle")], text=True).splitlines()
    records = []
    for index, (control, width, height, amount, scale, pattern) in enumerate(cases):
        params = json.loads(lines[index*3+1])
        records.append(dict(control=control, width=width, height=height, amount=amount, scale=scale, pattern=pattern,
                            sigma=params[0] if params[0] else None,
                            epsilon=params[1] if control == "luminance" and params[0] else None,
                            blend=params[2], input=json.loads(lines[index*3]), output=json.loads(lines[index*3+2])))
    result = dict(schema_version=1, upstream_commit=COMMIT, source_sha256=SOURCES,
                  generator="Unchanged original Rust detail_scale, nr_radius, nr_params, apply_nr, guided and Gaussian functions; LC-03 std-only storage/serial scheduling shim",
                  scope="Opaque original Rec2020 RGB; fixed detail/colorDetail/smoothness 50. Alpha normalization and unknown-sampling epsilon policy are separately tested PicEdit adaptations.",
                  absolute_float_tolerance=0.000005, relative_float_tolerance=0.000002, cases=records)
    target = pathlib.Path(__file__).with_name("vectors.json")
    if args.write:
        target.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Wrote {len(records)} pinned upstream denoise cases")
    elif json.loads(target.read_text()) != result:
        raise SystemExit("Pinned oracle does not reproduce vectors.json; inspect before --write")
    else:
        print(f"Verified {len(records)} pinned upstream denoise cases")


if __name__ == "__main__":
    main()

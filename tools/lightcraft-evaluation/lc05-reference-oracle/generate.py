#!/usr/bin/env python3
"""Reproduce LC-05 vectors using pinned original Rust colour algorithms.

Only optional regeneration needs rustc and a local Lightcraft checkout. Reads
git objects, never modifies the checkout, and has no Cargo dependencies.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile

COMMIT = "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15"
SOURCES = {
    "crates/pipeline/src/colorops.rs": "8ba34984474db9b4348ddea804f1c5a3e62e1fbfe4f6f5ea5ad033622654051e",
    "crates/color/src/perceptual.rs": "64c0f55d2e0266ba09d98d79dee015b970e176bc9c6248ebcd0fcec38d78fcb5",
    "crates/color/src/transfer.rs": "94f8206374134a338fa5c619f83f12315e9cb0ba8a9845206c8a93c3d387f9a9",
    "crates/color/src/lib.rs": "167ea499069e9dda021d4a4b6e0c196ea75abbea33da08dbaa0f91e4071cc4b2",
    "crates/pipeline/src/finish.rs": "1ae53438884cbad585f7488f08a12edac5156432df26036c9840cb89d4d2a19b",
    "crates/pipeline/src/output.rs": "36885aeee9479538208dc831039da68797aff35b4ccf34d0d07952938d00681d",
}


def function(source, name):
    match = re.search(r"^(?:pub )?fn " + re.escape(name) + r"\b", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing original function: {name}")
    opening = source.index("{", match.start())
    depth, index = 1, opening + 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[match.start():index]


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
    if "OutputSpace::Srgb => [0.2126, 0.7152, 0.0722]" not in sources["output"]:
        raise SystemExit("Pinned sRGB output luminance weights changed")
    # Keep all matrix/primary/white-point arithmetic unchanged. Only remove
    # serde derives, which are serialization metadata, not executed algorithms.
    core = sources["lib"].split("/// Row-major 3×3 matrix.")[1].split("/// Rec.2020 luminance weights")[0]
    core = core.replace(", Serialize, Deserialize", "").replace(", Serialize", "")
    perceptual = sources["perceptual"].split("#[cfg(test)]")[0]
    perceptual = "\n".join(line for line in perceptual.splitlines() if not line.startswith("//!"))
    program = "#![allow(dead_code)]\nextern crate self as lightcraft_color;\n" + core
    program += "\nmod perceptual {\n" + perceptual + "\n}\n"
    program += "mod transfer {\n" + function(sources["transfer"], "srgb_to_linear") + "\n}\n"
    program += "use std::f32::consts::{PI,TAU};\nuse perceptual::{hsv_to_rgb,lab_to_lch,oklab_from_2020,oklab_to_2020};\n"
    program += function(sources["colorops"], "wrap") + "\n"
    program += function(sources["colorops"], "oklch_hue_of_srgb_hue") + "\n"
    program += function(sources["finish"], "gamut_map_to") + "\n"
    # Only the original fast chroma-only branch executes with mixer/points/BW/
    # grading/local_hue disabled. Extract its statements verbatim, retaining
    # both signed cube-root transforms and the original saturation order.
    color = sources["colorops"]
    first = color.index("let mut lab = lab;", color.index("pub fn apply(&self, rgb:"))
    last = color.index("return self.grade(lab);", first) + len("return self.grade(lab);")
    block = color[first:last]
    program += "struct ColorOps { vibrance:f32,saturation:f32,skin:f32 }\nimpl ColorOps {\n"
    program += "fn grade(&self, lab:[f32;3])->[f32;3] { oklab_to_2020(lab) }\n"
    program += "fn apply(&self,rgb:[f32;3])->[f32;3] { if self.vibrance==0.0 && self.saturation==0.0 { return rgb; }\n"
    program += "let local_sat=0.0f32; let lab=oklab_from_2020(rgb);\n" + block + "\n}\n}\n"
    samples = [[0, 0, 0], [0.18, 0.18, 0.18], [1, 1, 1], [0.00000001, 0.00000002, 0.00000003],
               [0.4, 0.1, 0.05], [0.35, 0.16, 0.09], [0.03, 0.05, 0.4], [0.2, 0.21, 0.22],
               [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, 0, 1], [0, 1, 1],
               [-0.2, 0.4, 1.3], [-0.6, -0.2, -0.1], [-1, 0.1, 0.3], [2, 1.5, 0.3],
               [0.18, 0.1800001, 0.1799999], [0.7, 0.16, 0.01]]
    settings = [(0, 0), (0, -1), (0, -0.4), (0, 0.4), (0, 1), (-1, 0), (-0.4, 0), (0.4, 0), (1, 0), (1, 1), (-1, -1), (0.6, -0.3)]
    cases = [(domain, v, s) for domain in ("rec2020", "linear-srgb") for v, s in settings]
    program += "fn main() {\nprintln!(\"{:?}\",perceptual::oklab_matrices());\nprintln!(\"{:?}\",oklch_hue_of_srgb_hue(25.0));\n"
    for domain, vibrance, saturation in cases:
        # Rust does not coerce integer array literals into f32 in this nested
        # expression, so explicitly format every component with a decimal point.
        literal = "[" + ",".join("[" + ",".join(f"{float(c)!r}f32" for c in p) + "]" for p in samples) + "]"
        program += f"let input:{'[[f32;3];'+str(len(samples))+']'}={literal};\n"
        program += f"let ops=ColorOps{{vibrance:{float(vibrance)!r}f32,saturation:{float(saturation)!r}f32,skin:oklch_hue_of_srgb_hue(25.0)}};\n"
        if domain == "rec2020":
            program += "let raw=input.map(|p|ops.apply(p));\nlet mapped=raw;\n"
        else:
            program += "let raw=input.map(|p| if ops.vibrance==0.0 && ops.saturation==0.0 {p} else {REC2020.to_space(&SRGB).apply_f32(ops.apply(SRGB.to_space(&REC2020).apply_f32(p)))});\n"
            program += "let mapped=raw.map(|p|if ops.vibrance==0.0 && ops.saturation==0.0 {p} else {gamut_map_to(p,[0.2126,0.7152,0.0722],1.0).0});\n"
        program += 'println!("{:?}",input);println!("{:?}",raw);println!("{:?}",mapped);\n'
    program += "}\n"
    with tempfile.TemporaryDirectory(prefix="glowroom-lc05-oracle-") as directory:
        root = pathlib.Path(directory)
        source = root / "oracle.rs"
        source.write_text(program)
        subprocess.run(["rustc", "--edition=2024", "-O", str(source), "-o", str(root / "oracle")], check=True)
        lines = subprocess.check_output([str(root / "oracle")], text=True).splitlines()
    records = []
    for index, (domain, vibrance, saturation) in enumerate(cases):
        records.append(dict(domain=domain, vibrance=vibrance, saturation=saturation,
                            input=json.loads(lines[2 + index*3]), raw=json.loads(lines[3 + index*3]),
                            mapped=json.loads(lines[4 + index*3])))
    result = dict(schema_version=1, upstream_commit=COMMIT, source_sha256=SOURCES,
                  generator="Original Rust matrices/transforms and unchanged ColorOps chroma-only branch; optional original gamut_map_to",
                  absolute_float_tolerance=0.000005, matrices=json.loads(lines[0]), skin_hue=json.loads(lines[1]), cases=records)
    target = pathlib.Path(__file__).with_name("vectors.json")
    if args.write:
        target.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Wrote {len(records)} pinned upstream colour cases, {len(samples)} pixels each")
    elif json.loads(target.read_text()) != result:
        raise SystemExit("Pinned oracle does not reproduce vectors.json; inspect before --write")
    else:
        print(f"Verified {len(records)} pinned upstream colour cases, {len(samples)} pixels each")


if __name__ == "__main__":
    main()

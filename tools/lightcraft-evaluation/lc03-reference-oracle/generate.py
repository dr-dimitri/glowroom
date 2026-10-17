#!/usr/bin/env python3
"""Regenerate independent LC-03 numeric vectors from pinned, unchanged Rust functions.

Only regeneration needs Python, rustc and an existing Lightcraft checkout. Neither
Swift tests nor PicEdit builds execute this tool or depend on Rust/Lightcraft.
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
    "crates/pipeline/src/local.rs": "6bf40e393316a8588fe4180fb53d09a0bf4ee0e1c3e27986111de30500682c66",
    "crates/raster/src/blur.rs": "d558651ea86c1dcf66aaca77805e954911da51d4c10f6ec3908be232a11e8266",
    "crates/raster/src/resample.rs": "0467828b73e65379908c14a3c6308e3e11205e3a0014fc0ac67c97c1a4b20e51",
}
LOCAL_SYMBOLS = ["guided", "guided_coeffs", "guided_apply", "guided_fast", "median_hv",
                 "median_row", "transpose", "tone_base", "guided_fast_step"]

# This compatibility shell supplies storage and deterministic row iteration. The
# algorithm bodies come only from the source files validated above. Running these
# small oracle fixtures serially avoids importing Rayon or changing arithmetic.
SHELL = r"""
#![allow(dead_code)]
#[derive(Clone)]
pub struct Image<T> { pub width: usize, pub height: usize, pub data: Vec<T> }
pub type Plane = Image<f32>;
impl<T: Copy + Default> Image<T> {
    pub fn new(width: usize, height: usize) -> Self {
        Self { width, height, data: vec![T::default(); width * height] }
    }
    pub fn row(&self, y: usize) -> &[T] { &self.data[y*self.width..(y+1)*self.width] }
    pub fn get_clamped(&self, x: isize, y: isize) -> T {
        self.data[y.clamp(0, self.height as isize - 1) as usize * self.width
            + x.clamp(0, self.width as isize - 1) as usize]
    }
    pub fn from_fn(width: usize, height: usize, f: impl Fn(usize, usize) -> T) -> Self {
        let mut out = Self::new(width, height);
        for y in 0..height { for x in 0..width { out.data[y*width+x] = f(x,y); } }
        out
    }
    pub fn map<U: Copy + Default>(&self, f: impl Fn(T) -> U) -> Image<U> {
        Image { width: self.width, height: self.height, data: self.data.iter().map(|v| f(*v)).collect() }
    }
    pub fn zip_map(&self, other: &Self, f: impl Fn(T,T) -> T) -> Self {
        Self { width: self.width, height: self.height,
            data: self.data.iter().zip(&other.data).map(|(a,b)| f(*a,*b)).collect() }
    }
}
pub fn par_rows<T>(data: &mut [T], width: usize, f: impl Fn(usize, &mut [T])) {
    for (y, row) in data.chunks_mut(width).enumerate() { f(y,row); }
}
pub use par_rows as for_rows;
pub fn par_join<A,B>(a: impl FnOnce() -> A, b: impl FnOnce() -> B) -> (A,B) { (a(),b()) }
"""


def function(source, name):
    """Select the unchanged top-level Rust body; hashes pin this simple parser's input."""
    match = re.search(r"^(?:pub )?fn " + re.escape(name) + r"\b", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing original function: {name}")
    opening = source.index("{", match.start())
    depth = 1
    index = opening + 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[match.start():index]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=pathlib.Path)
    parser.add_argument("--write", action="store_true", help="Explicitly replace vectors.json")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(args.checkout), "rev-parse", "HEAD"], text=True).strip()
    if head != COMMIT:
        raise SystemExit(f"Expected Lightcraft commit {COMMIT}; found {head}")
    sources = {}
    for name, expected in SOURCES.items():
        data = (args.checkout / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit(f"Source does not match pin: {name}")
        sources[pathlib.Path(name).stem] = data.decode()
    # The full unchanged resample/blur modules exclude only their own test modules.
    modules = "\n".join("mod " + name + " {\n" + sources[name].split("#[cfg(test)]")[0] + "\n}"
                        for name in ("resample", "blur"))
    local = "\n".join(function(sources["local"], name) for name in LOCAL_SYMBOLS)
    # Re-exporting aliases satisfies the original imports without crate dependencies.
    local = "extern crate self as lightcraft_raster;\nuse blur::gaussian;\nconst BASE_EPS: f32 = 0.1;\n" + local
    epsilon = re.search(r"pub const BASE_EPS: f32 = ([^;]+);", sources["local"])
    if epsilon is None:
        raise SystemExit("Missing original BASE_EPS")
    local = local.replace("const BASE_EPS: f32 = 0.1;", "const BASE_EPS: f32 = " + epsilon[1] + ";")
    cases = [
        ("median", 7, 5, 0.0, 2, 7, 5),
        ("gaussian", 7, 5, 0.2, 0, 7, 5),
        ("gaussian", 7, 5, 1.0, 0, 7, 5),
        ("gaussian", 7, 5, 2.5, 0, 7, 5),
        ("gaussian", 4, 35, 8.0, 0, 4, 35),
        ("gaussian", 4, 3, 1e9, 0, 4, 3),
        ("guided", 9, 7, 4.5, 0, 9, 7),
        ("guided", 9, 7, 18.0, 0, 9, 7),
        ("tone_base", 13, 9, 7.5, 2, 13, 9),
        ("resize_box", 7, 5, 0.0, 0, 4, 3),
        ("resize_bilinear", 7, 5, 0.0, 0, 11, 8),
    ]
    program = ["fn main() {"]
    for op, w, h, sigma, radius, ow, oh in cases:
        program.append(f"let p = Plane::from_fn({w}, {h}, |x,y| "
                       "(((x * 31 + y * 17) * 2_654_435_761usize) % 1000) as f32 / 250.0 - 2.0 "
                       "+ if x % 5 == 0 { 0.5 } else { 0.0 });")
        expression = {
            "median": f"median_hv(&p, {radius})",
            "gaussian": f"gaussian(&p, {sigma}f32)",
            "guided": f"guided_fast(&p, {sigma}f32, BASE_EPS)",
            "tone_base": f"tone_base(&p, {sigma}f32, {radius})",
            "resize_box": f"resample::resize(&p, {ow}, {oh}, resample::Filter::Box)",
            "resize_bilinear": f"resample::resize(&p, {ow}, {oh}, resample::Filter::Bilinear)",
        }[op]
        program += [f"let output = {expression};", 'println!("{:?}", p.data);', 'println!("{:?}", output.data);']
    program.append("}")
    with tempfile.TemporaryDirectory(prefix="picedit-lc03-oracle-") as directory:
        root = pathlib.Path(directory)
        source = root / "oracle.rs"
        source.write_text(SHELL + modules + local + "\n".join(program))
        subprocess.run(["rustc", "--edition=2024", "-O", str(source), "-o", str(root / "oracle")], check=True)
        lines = subprocess.check_output([str(root / "oracle")], text=True).splitlines()
    records = []
    for index, (op, w, h, sigma, radius, ow, oh) in enumerate(cases):
        records.append(dict(operation=op, width=w, height=h, sigma=sigma, radius=radius,
                            output_width=ow, output_height=oh, epsilon=float(epsilon[1]),
                            input=json.loads(lines[index*2]), output=json.loads(lines[index*2+1])))
    result = dict(schema_version=1, upstream_commit=COMMIT, source_sha256=SOURCES,
                  generator="Original Rust functions, std-only storage/serial scheduling shim",
                  absolute_float_tolerance=0.000005, cases=records)
    target = pathlib.Path(__file__).with_name("vectors.json")
    if args.write:
        target.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Wrote {len(records)} upstream numeric cases: {target}")
    elif json.loads(target.read_text()) != result:
        raise SystemExit("Pinned oracle does not reproduce vectors.json; inspect before --write")
    else:
        print(f"Verified {len(records)} pinned upstream numeric cases")


if __name__ == "__main__":
    main()

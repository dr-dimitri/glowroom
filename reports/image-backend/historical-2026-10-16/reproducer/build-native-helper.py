"""Build ONLY when Root grants the next exclusive evaluation window.

The original source tree and baseline static archive are read-only inputs.
Three independent object compilations (max2 concurrent) use max2 jobs. Archive replacement, index,
then helper link are sequential. No download, model loading, or inference.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).parent
SOURCE = ROOT / "source"
BUILD = ROOT / "build-metal"
DEST = ROOT / "float-diagnostic-unbatched-build"
DEST.mkdir(exist_ok=True)
CXX = "/Library/Developer/CommandLineTools/usr/bin/c++"
SDK = "/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk"
FLAGS = ["-std=gnu++17", "-O3", "-DNDEBUG", "-DGGML_MAX_NAME=160", "-DGGML_USE_BLAS", "-DGGML_USE_CPU", "-DGGML_USE_METAL", "-DONIG_STATIC", "-DUTF8PROC_STATIC", "-isysroot", SDK, "-mmacosx-version-min=14.0"]
INCLUDES = [ROOT, SOURCE, SOURCE / "src", SOURCE / "src/core", SOURCE / "src/pipeline", SOURCE / "include", SOURCE / "ggml/include", SOURCE / "ggml/src", SOURCE / "thirdparty", SOURCE / "thirdparty/oniguruma", SOURCE / "thirdparty/utf8proc"]
for path in INCLUDES:
    FLAGS += ["-I", str(path)]
OBJECTS = [
    (ROOT / "instrumented-source-unbatched/src/core/ggml_runner.cpp", DEST / "ggml_runner.cpp.o"),
    (ROOT / "instrumented-source-unbatched/src/pipeline/diffusion_engine.cpp", DEST / "diffusion_engine.cpp.o"),
    (ROOT / "instrumented-source-unbatched/src/pipeline/image.cpp", DEST / "image.cpp.o"),
]


def run(command, log):
    with log.open("wb") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)


def compile_object(entry):
    source, obj = entry
    run([CXX, *FLAGS, "-c", str(source), "-o", str(obj)], obj.with_suffix(".log"))
    return str(obj)


baseline = BUILD / "libstable-diffusion.a"
baseline_digest = hashlib.sha256(baseline.read_bytes()).hexdigest()
with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(compile_object, OBJECTS))
archive = DEST / "libstable-diffusion-float-diagnostic-unbatched.a"
shutil.copy2(baseline, archive)
run(["/usr/bin/ar", "-r", str(archive), *[str(obj) for _, obj in OBJECTS]], DEST / "replace-objects.log")
run(["/usr/bin/ranlib", str(archive)], DEST / "ranlib.log")
libraries = [archive, BUILD / "ggml/src/libggml.a", BUILD / "ggml/src/libggml-cpu.a", BUILD / "ggml/src/ggml-blas/libggml-blas.a", BUILD / "ggml/src/ggml-metal/libggml-metal.a", BUILD / "ggml/src/libggml-base.a"]
binary = ROOT / "evaluation-helper-float-diagnostic-unbatched"
run([CXX, *FLAGS, str(ROOT / "evaluation-helper-float-diagnostic-unbatched.cpp"), *map(str, libraries), "-framework", "Accelerate", "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalKit", "-o", str(binary)], DEST / "link-helper.log")
assert hashlib.sha256(baseline.read_bytes()).hexdigest() == baseline_digest
report = {"status": "compiled-no-inference", "baselineArchiveSHA256": baseline_digest, "instrumentedArchiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(), "helperSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "maximumCompileJobs": 2}
(DEST / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))

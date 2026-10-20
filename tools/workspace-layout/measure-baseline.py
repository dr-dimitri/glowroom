#!/usr/bin/env python3
"""Measure the historical Issue 45 UI with the same native test and image pipeline.

The two historical view files are compiled in a disposable project copy. Only
their type names and an accessibility marker change. No working tree mutation.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "fba0c9bbf629360ade8e61357cb8a082b14564ef"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--jobs", default="4")
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="glowroom-layout-baseline-") as temporary:
    project = Path(temporary)
    for name in ("Sources", "scripts"):
        shutil.copytree(ROOT / name, project / name)
    for name in ("Package.swift", "Package.resolved"):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, project / name)
    tests = project / "Tests/GlowroomTests"
    tests.mkdir(parents=True)
    shutil.copy2(ROOT / "Tests/GlowroomTests/WorkspaceGeometryTests.swift", tests)
    shutil.copy2(ROOT / "Tests/GlowroomTests/WorkspaceAccessibility.swift", tests)
    core_tests = project / "Tests/GlowroomCoreTests"
    core_tests.mkdir()
    (core_tests / "Placeholder.swift").write_text("// Geometry-only disposable project.\n")
    for name in ("LibraryView", "PhotoGridView"):
        source = subprocess.check_output(
            ["git", "show", f"{BASELINE}:Sources/PicEdit/{name}.swift"], cwd=ROOT, text=True)
        # Only the archived Git path uses the former name. Compile against current modules.
        source = source.replace("import PicEditCore", "import GlowroomCore")
        for original in ("LibraryView", "PhotoGridView", "DetailView"):
            source = re.sub(rf"\b{original}\b", "Historical" + original, source)
        if name == "PhotoGridView":
            source = source.replace('struct HistoricalDetailView: View {',
                'struct HistoricalDetailView: View {\n    @Environment(\\.workspaceCanvasMeasurement) private var measureCanvas')
            marker = '}.contextMenu { PhotoContextMenu(asset: asset, model: model) }'
            assert source.count(marker) == 1
            source = source.replace(marker, marker + '\n                .onGeometryChange(for: CGSize.self) { $0.size } action: { measureCanvas?($0) }'
                '\n                .accessibilityElement(children: .contain)'
                '\n                .accessibilityLabel("Bildfläche")'
                '\n                .accessibilityIdentifier("workspace.canvas")')
        target = project / "Tests/GlowroomTests" / f"Historical{name}.swift"
        target.write_text("@testable import Glowroom\n" + source)
    environment = dict(os.environ, GLOWROOM_WORKSPACE_MEASUREMENTS=str(output),
                       GLOWROOM_TEST_BUILD_PATH=str(project / ".build"))
    subprocess.run([str(project / "scripts/test.sh"), "--jobs", args.jobs,
                    "-Xswiftc", "-DGLOWROOM_WORKSPACE_BASELINE", "--filter", "WorkspaceGeometryTests"],
                   cwd=project, env=environment, check=True)
    (output / "native-layout-measurements.json").rename(output / "baseline-layout-measurements.json")

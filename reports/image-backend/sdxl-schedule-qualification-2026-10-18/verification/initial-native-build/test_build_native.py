"""Offline builder contract tests; never invoke a compiler or model."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("sdxl_build_native", Path(__file__).with_name("build_native.py"))
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class NativeBuilderTests(unittest.TestCase):
    def source(self, cache, member="sdk/include/example.h"):
        path = cache / "source.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            data = b"evaluation source fixture\n"
            entry = tarfile.TarInfo(member)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        return {"name": path.name, "bytes": path.stat().st_size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "revision": "fixture-only", "destination": "source"}

    def test_corrupt_cache_stops_before_tools_or_build_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "evaluation"; root.mkdir()
            cache = Path(folder) / "cache"; cache.mkdir()
            entry = self.source(cache)
            (cache / entry["name"]).write_bytes(b"corruption")
            with mock.patch.object(BUILDER, "SOURCES", [entry]), \
                    mock.patch.object(BUILDER.subprocess, "check_output") as probe, \
                    mock.patch.object(BUILDER.PREPARATION, "run_checked") as command:
                with self.assertRaises(BUILDER.PreparationError):
                    BUILDER.build(root, source_cache=cache)
            probe.assert_not_called(); command.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_changed_frozen_mask_stops_before_tools_or_build_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "evaluation"; root.mkdir()
            cache = Path(folder) / "cache"; cache.mkdir()
            entry = self.source(cache)
            bad_fixture = Path(folder) / "mask.png"; bad_fixture.write_bytes(b"changed mask")
            with mock.patch.object(BUILDER, "SOURCES", [entry]), \
                    mock.patch.object(BUILDER, "MASK_FIXTURE", bad_fixture), \
                    mock.patch.object(BUILDER.subprocess, "check_output") as probe, \
                    mock.patch.object(BUILDER.PREPARATION, "run_checked") as command:
                with self.assertRaisesRegex(BUILDER.PreparationError, "fixture SHA-256"):
                    BUILDER.build(root, source_cache=cache)
            probe.assert_not_called(); command.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_foreign_output_is_preserved_before_source_access(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            helper = root / "sdxl-helper"; helper.write_bytes(b"keep foreign helper")
            with mock.patch.object(BUILDER.PREPARATION, "verify") as verify:
                with self.assertRaises(BUILDER.PreparationError):
                    BUILDER.build(root, source_cache=root / "missing")
            verify.assert_not_called()
            self.assertEqual(helper.read_bytes(), b"keep foreign helper")

    def test_symbolic_cache_and_symbolic_archive_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            root = parent / "evaluation"; root.mkdir()
            cache = parent / "cache"; cache.mkdir()
            entry = self.source(cache)
            alias = parent / "alias"; alias.symlink_to(cache, target_is_directory=True)
            with self.assertRaises(BUILDER.PreparationError):
                BUILDER.build(root, source_cache=alias)
            actual = cache / entry["name"]
            preserved = cache / "preserved"; actual.rename(preserved); actual.symlink_to(preserved)
            with mock.patch.object(BUILDER, "SOURCES", [entry]):
                with self.assertRaises(BUILDER.PreparationError):
                    BUILDER.build(root, source_cache=cache)
            self.assertTrue(preserved.is_file())

    def test_safe_extractor_rejects_traversal_and_does_not_publish_helper(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            cache = parent / "cache"; cache.mkdir()
            entry = self.source(cache, member="sdk/../../escaped")
            with self.assertRaises(BUILDER.PreparationError):
                BUILDER.PREPARATION.extract_sources(cache / entry["name"], parent / "stage", entry)
            self.assertFalse((parent / "escaped").exists())

    def test_failed_build_cleans_only_private_stage_and_preserves_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "evaluation"; root.mkdir()
            cache = Path(folder) / "cache"; cache.mkdir()
            entry = self.source(cache)
            before = (cache / entry["name"]).read_bytes()
            foreign = root / ".sdxl-native-foreign"; foreign.mkdir()
            (foreign / "keep").write_text("preserve")
            with mock.patch.object(BUILDER, "SOURCES", [entry]), \
                    mock.patch.object(BUILDER.platform, "system", return_value="Darwin"), \
                    mock.patch.object(BUILDER.platform, "machine", return_value="arm64"), \
                    mock.patch.object(BUILDER.subprocess, "check_output", return_value="/fixture/tool\n"), \
                    mock.patch.object(BUILDER, "verify_schedule_strength_contract"), \
                    mock.patch.object(BUILDER.PREPARATION, "run_checked", side_effect=BUILDER.PreparationError("fixture failure")):
                with self.assertRaises(BUILDER.PreparationError):
                    BUILDER.build(root, cmake=Path(__file__), source_cache=cache)
            self.assertEqual((cache / entry["name"]).read_bytes(), before)
            self.assertEqual((foreign / "keep").read_text(), "preserve")
            self.assertEqual(list(root.iterdir()), [foreign])

    def test_unsafe_roots_are_rejected_before_source_or_lock_access(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "evaluation"; root.mkdir()
            with mock.patch.object(BUILDER.PREPARATION, "verify") as verify:
                for mode in [0o777, 0o770, 0o702]:
                    root.chmod(mode)
                    with self.assertRaises(BUILDER.PreparationError):
                        BUILDER.build(root)
                root.chmod(0o700)
                with mock.patch.object(BUILDER.os, "getuid", return_value=os.getuid() + 1):
                    with self.assertRaises(BUILDER.PreparationError):
                        BUILDER.build(root)
                for path in [BUILDER.REPOSITORY, BUILDER.REPOSITORY.parent, Path("/private/tmp")]:
                    with self.assertRaises(BUILDER.PreparationError):
                        BUILDER.build(path)
            verify.assert_not_called()
            self.assertFalse((root / ".sdxl-native-build.lock").exists())

    def test_unsafe_locks_are_rejected_and_preserved(self):
        for mode in ["symbolic", "hardlink", "fifo", "shared-write", "foreign-owner"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                lock = root / ".sdxl-native-build.lock"
                target = root / "preserved"
                target.write_bytes(b"foreign lock must survive")
                if mode == "symbolic":
                    lock.symlink_to(target)
                elif mode == "hardlink":
                    os.link(target, lock)
                elif mode == "fifo":
                    os.mkfifo(lock)
                else:
                    lock.write_bytes(b"foreign lock must survive")
                    if mode == "shared-write":
                        lock.chmod(0o666)
                with mock.patch.object(BUILDER.fcntl, "flock") as flock:
                    if mode == "foreign-owner":
                        with mock.patch.object(BUILDER.os, "getuid", return_value=os.getuid() + 1):
                            with self.assertRaises(BUILDER.PreparationError):
                                BUILDER.open_build_lock(root)
                    else:
                        with self.assertRaises((BUILDER.PreparationError, OSError)):
                            BUILDER.open_build_lock(root)
                flock.assert_not_called()
                self.assertTrue(lock.exists() or lock.is_symlink())
                self.assertEqual(target.read_bytes(), b"foreign lock must survive")

    def test_valid_lock_is_retained_after_the_descriptor_closes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with BUILDER.open_build_lock(root) as lock:
                self.assertEqual(os.fstat(lock.fileno()).st_nlink, 1)
            self.assertTrue((root / ".sdxl-native-build.lock").is_file())

    def test_failed_native_regression_never_publishes_helper_or_receipt(self):
        # No real compiler/GPU: fail each ordered regression boundary after
        # mocked tools. A failure must preserve inputs and deny readiness.
        ordered = ["sdxl-mask-baseline", "sdxl-schedule-baseline", "sdxl-schedule-reference",
                   "metal-group-norm-baseline", "metal-group-norm-patched", "sdxl-mask-patched"]
        for boundary in ordered:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as folder:
                root = Path(folder) / "evaluation"; root.mkdir()
                cache = Path(folder) / "cache"; cache.mkdir()
                entry = self.source(cache)
                original = (cache / entry["name"]).read_bytes()
                reached = []

                def command(arguments, log):
                    name = Path(arguments[0]).name
                    if name == "sdxl-schedule-regression":
                        name = "sdxl-schedule-baseline" if len(arguments) == 2 else "sdxl-schedule-reference"
                    if name in ordered:
                        reached.append(name)
                    if name == boundary:
                        if boundary == "metal-group-norm-baseline":
                            self.assertIn("--expect-baseline-bug", arguments)
                        raise BUILDER.PreparationError("fixture regression failure")

                with mock.patch.object(BUILDER, "SOURCES", [entry]), \
                        mock.patch.object(BUILDER.platform, "system", return_value="Darwin"), \
                        mock.patch.object(BUILDER.platform, "machine", return_value="arm64"), \
                        mock.patch.object(BUILDER.subprocess, "check_output", return_value="/fixture/tool\n"), \
                        mock.patch.object(BUILDER, "verify_schedule_strength_contract"), \
                        mock.patch.object(BUILDER.PREPARATION, "run_checked", side_effect=command):
                    with self.assertRaisesRegex(BUILDER.PreparationError, "fixture regression failure"):
                        BUILDER.build(root, cmake=Path(__file__), source_cache=cache)
                expected = ordered[:ordered.index(boundary) + 1]
                self.assertEqual(reached, expected)
                self.assertFalse((root / "sdxl-helper").exists())
                self.assertFalse((root / "native-installation.json").exists())
                self.assertEqual(list(root.iterdir()), [])
                self.assertEqual((cache / entry["name"]).read_bytes(), original)

    def test_changed_strength_slice_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)
            image = source / "src/pipeline/image.cpp"
            image.parent.mkdir(parents=True)
            image.write_text("t_enc = static_cast<size_t>(plan->sample_steps * request->strength);\n")
            with self.assertRaisesRegex(BUILDER.PreparationError, "image-strength slicing"):
                BUILDER.verify_schedule_strength_contract(source)


if __name__ == "__main__":
    unittest.main()

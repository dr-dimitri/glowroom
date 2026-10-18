"""Offline integration/safety checks with tiny payloads, never model downloads."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("prepare_lama", Path(__file__).with_name("prepare.py"))
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def fixture(cache):
    payloads = {"LaMa.mlpackage/Manifest.json": b'{"fixture": true}\n',
                "LaMa.mlpackage/Data/model.bin": bytes(range(80)),
                "README.md": b"Evaluation provenance fixture\n"}
    for name, data in payloads.items():
        path = cache / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    package = {"schemaVersion": 1, "purpose": "technical-evaluation-only",
               "repository": "fixture/fixture", "revision": "pinned-fixture",
               "files": [{"path": name, "bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest()}
                         for name, data in payloads.items()]}
    return package, payloads


class PreparationTests(unittest.TestCase):
    def test_default_plan_never_opens_network_or_creates_requested_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "unused"
            output = io.StringIO()
            with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(PREPARE.main(["--root", str(root)]), 0)
            plan = json.loads(output.getvalue())
            self.assertEqual(plan["action"], "plan")
            self.assertFalse(plan["network"])
            self.assertEqual(plan["totalBytes"], 216650601)
            self.assertFalse(root.exists())

    def test_offline_install_publishes_exact_payloads_and_pinned_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            package, payloads = fixture(parent / "cache")
            with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")):
                installed = PREPARE.install(package, parent / "install", parent / "cache")
            for path, expected in payloads.items():
                self.assertEqual((installed / path).read_bytes(), expected)
            receipt = json.loads((installed / "installation.json").read_text())
            self.assertEqual(receipt["revision"], "pinned-fixture")
            self.assertEqual(receipt["files"], package["files"])
            self.assertEqual([path.name for path in (parent / "install").iterdir()], ["model"])

    def test_missing_corrupt_truncated_and_oversized_cache_never_publish_or_leave_staging(self):
        for mode in ["missing", "corrupt", "truncated", "oversized"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                parent = Path(temporary)
                package, _ = fixture(parent / "cache")
                source = parent / "cache/LaMa.mlpackage/Data/model.bin"
                if mode == "missing":
                    source.unlink()
                else:
                    source.write_bytes({"corrupt": b"X" * 80, "truncated": b"X", "oversized": b"X" * 81}[mode])
                root = parent / "install"
                root.mkdir()
                (root / "keep.txt").write_bytes(b"unrelated")
                with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")):
                    with self.assertRaises((PREPARE.PreparationError, OSError)):
                        PREPARE.install(package, root, parent / "cache")
                self.assertEqual([path.name for path in root.iterdir()], ["keep.txt"])
                self.assertEqual((root / "keep.txt").read_bytes(), b"unrelated")

    def test_cache_symlinks_hardlinks_and_nonregular_payloads_are_rejected(self):
        for mode in ["symbolic-file", "symbolic-directory", "symbolic-cache", "hardlink", "fifo"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                parent = Path(temporary)
                cache = parent / "cache"
                package, _ = fixture(cache)
                source = cache / "LaMa.mlpackage/Data/model.bin"
                if mode == "symbolic-file":
                    source.rename(parent / "outside.bin")
                    source.symlink_to(parent / "outside.bin")
                elif mode == "symbolic-directory":
                    source.parent.rename(parent / "outside")
                    source.parent.symlink_to(parent / "outside", target_is_directory=True)
                elif mode == "symbolic-cache":
                    cache.rename(parent / "outside")
                    cache.symlink_to(parent / "outside", target_is_directory=True)
                elif mode == "hardlink":
                    os.link(source, parent / "alias.bin")
                else:
                    source.unlink()
                    os.mkfifo(source)
                with self.assertRaises((PREPARE.PreparationError, OSError)):
                    PREPARE.install(package, parent / "install", cache)
                self.assertEqual(list((parent / "install").iterdir()), [])

    def test_existing_model_or_foreign_lock_is_preserved(self):
        for mode in ["model", "lock"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                parent = Path(temporary)
                package, _ = fixture(parent / "cache")
                root = parent / "install"
                root.mkdir()
                item = root / ("model" if mode == "model" else ".installation.lock")
                item.write_bytes(b"must survive")
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.install(package, root, parent / "cache")
                self.assertEqual(item.read_bytes(), b"must survive")
                self.assertEqual(list(root.iterdir()), [item])

    def test_offline_without_cache_fails_before_creating_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "install"
            with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(PREPARE.main(["--offline", "--root", str(root)]), 1)
            self.assertFalse(root.exists())

    def test_repository_destination_and_package_traversal_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            package, _ = fixture(parent / "cache")
            with self.assertRaises(PREPARE.PreparationError):
                PREPARE.install(package, PREPARE.REPOSITORY / "unwanted-evaluation", parent / "cache")
            self.assertFalse((PREPARE.REPOSITORY / "unwanted-evaluation").exists())
            package["files"][0]["path"] = "../escape"
            with self.assertRaises(PREPARE.PreparationError):
                PREPARE.install(package, parent / "install", parent / "cache")
            self.assertFalse((parent / "install").exists())
            self.assertFalse((parent / "escape").exists())

    def test_failed_publication_preserves_destination_and_cleans_only_owned_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            package, _ = fixture(parent / "cache")
            root = parent / "install"
            root.mkdir()
            preserved = root / ".lama-install-unrelated"
            preserved.mkdir()
            with patch.object(Path, "rename", side_effect=PermissionError("publication denied")):
                with self.assertRaises(PermissionError):
                    PREPARE.install(package, root, parent / "cache")
            self.assertEqual(list(root.iterdir()), [preserved])


if __name__ == "__main__":
    unittest.main()

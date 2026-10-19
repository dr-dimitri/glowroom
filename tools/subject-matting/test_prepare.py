"""Source acquisition guards, exercised without network or model dependencies."""
import hashlib
import io
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

import prepare


class SourceTests(unittest.TestCase):
    def test_unpinned_dependency_shadow_is_not_executed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source"
            trusted = directory / "trusted"
            source.mkdir(); trusted.mkdir()
            name = "picedit_test_safe_dependency"
            (source / (name + ".py")).write_text("raise RuntimeError('unpinned shadow executed')\n")
            (trusted / (name + ".py")).write_text("VALUE = 'safe'\n")
            (source / "BiRefNet_config.py").write_text("class BiRefNetConfig: pass\n")
            (source / "birefnet.py").write_text(
                "from .BiRefNet_config import BiRefNetConfig\n"
                f"import {name}\nRESULT = {name}.VALUE\n")
            before = list(sys.path)
            sys.path.append(str(trusted))
            try:
                hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                          for name in ("birefnet.py", "BiRefNet_config.py")}
                with patch.object(prepare, "FILES", hashes):
                    namespace = prepare.load_upstream_classes(source)
                self.assertEqual(namespace["RESULT"], "safe")
                self.assertNotIn(str(source), sys.path)
            finally:
                sys.path[:] = before
                sys.modules.pop(name, None)

    def test_source_changed_after_initial_check_is_not_executed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            expected = hashlib.sha256(b"safe source").hexdigest()
            (directory / "birefnet.py").write_bytes(b"modified source")
            with patch.object(prepare, "FILES", {"birefnet.py": expected}):
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    prepare.pinned_bytes(directory, "birefnet.py")

    @unittest.skipUnless(sys.platform == "darwin", "Uses macOS no-replace rename")
    def test_package_publication_preserves_existing_empty_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "staged"
            target = directory / "foreign"
            source.mkdir(); target.mkdir()
            (source / "model").write_bytes(b"owned")
            with self.assertRaises(FileExistsError):
                prepare.publish_directory(source, target)
            self.assertEqual(list(target.iterdir()), [])
            self.assertEqual((source / "model").read_bytes(), b"owned")

    @unittest.skipUnless(sys.platform == "darwin", "Uses macOS no-replace rename")
    def test_package_publication_moves_into_new_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "staged"
            source.mkdir()
            (source / "model").write_bytes(b"owned")
            target = directory / "complete"
            prepare.publish_directory(source, target)
            self.assertEqual((target / "model").read_bytes(), b"owned")
            self.assertFalse(source.exists())

    def test_pinned_download_preserves_foreign_partial(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            foreign = directory / "weights.partial"
            foreign.write_bytes(b"another process")
            with patch.object(prepare, "FILES", {"weights": hashlib.sha256(b"abc").hexdigest()}), \
                 patch("urllib.request.urlopen", return_value=io.BytesIO(b"abc")):
                prepare.sources(directory, download=True)
            self.assertEqual((directory / "weights").read_bytes(), b"abc")
            self.assertEqual(foreign.read_bytes(), b"another process")
            self.assertEqual(sorted(path.name for path in directory.iterdir()), ["weights", "weights.partial"])

    def test_checksum_failure_never_publishes_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(prepare, "FILES", {"weights": hashlib.sha256(b"abc").hexdigest()}), \
                 patch("urllib.request.urlopen", return_value=io.BytesIO(b"wrong")):
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    prepare.sources(directory, download=True)
            self.assertEqual(list(directory.iterdir()), [])

    def test_racing_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original_link = prepare.os.link

            def racing_link(source, destination):
                Path(destination).write_bytes(b"another preparer")
                original_link(source, destination)

            with patch.object(prepare, "FILES", {"weights": hashlib.sha256(b"abc").hexdigest()}), \
                 patch("urllib.request.urlopen", return_value=io.BytesIO(b"abc")), \
                 patch("os.link", side_effect=racing_link):
                with self.assertRaises(FileExistsError):
                    prepare.sources(directory, download=True)
            self.assertEqual((directory / "weights").read_bytes(), b"another preparer")
            self.assertEqual(len(list(directory.iterdir())), 1)

    def test_symlink_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "actual").mkdir()
            (directory / "link").symlink_to(directory / "actual", target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                prepare.sources(directory / "link", download=False)


if __name__ == "__main__":
    unittest.main()

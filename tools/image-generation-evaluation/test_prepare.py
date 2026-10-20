"""Offline safety checks: python3 -m unittest discover -s tools/image-generation-evaluation."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import sys
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "prepare_image_generation", Path(__file__).resolve().parents[2] / "scripts/prepare-image-generation-evaluation.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def entry(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


class PreparationTests(unittest.TestCase):
    def fixture_archive(self, root):
        archive = root / "archive"
        (archive / "provenance").mkdir(parents=True)
        (archive / "fixtures").mkdir()
        manifest = b'{"fixtures": []}'
        (archive / "provenance/fixtures-manifest.json").write_bytes(manifest)
        payload = b"small temporary fixture"
        (archive / "fixtures/source.png").write_bytes(payload)
        package = {"fixtureManifestSHA256": entry(manifest)["sha256"],
                   "fixtureFiles": [{"path": "fixtures/source.png", **entry(payload)}]}
        return archive, package

    def test_external_fixture_archive_is_verified_and_installed(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            archive, package = self.fixture_archive(root)
            destination = root / "installed"
            PREPARE.install_fixtures(destination, package, archive)
            self.assertEqual((destination / "fixtures/source.png").read_bytes(), b"small temporary fixture")
            self.assertEqual((destination / "fixtures-manifest.json").read_bytes(),
                             (archive / "provenance/fixtures-manifest.json").read_bytes())

    def test_missing_or_corrupt_fixture_archive_is_rejected_before_publication(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            archive, package = self.fixture_archive(root)
            destination = root / "installed"
            for path in [None, root / "missing", PREPARE.REPOSITORY]:
                with self.subTest(path=path), self.assertRaises(PREPARE.PreparationError):
                    PREPARE.install_fixtures(destination, package, path)
            self.assertFalse(destination.exists())
            (archive / "fixtures/source.png").write_bytes(b"changed")
            with self.assertRaisesRegex(PREPARE.PreparationError, "SHA256 mismatch"):
                PREPARE.install_fixtures(destination, package, archive)
            self.assertFalse(destination.exists())

    def test_fixture_archive_traversal_is_rejected_before_publication(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            archive, package = self.fixture_archive(root)
            package["fixtureFiles"][0]["path"] = "fixtures/../../outside"
            with self.assertRaisesRegex(PREPARE.PreparationError, "invalid pinned fixture path"):
                PREPARE.install_fixtures(root / "installed", package, archive)
            self.assertFalse((root / "installed").exists())

    def test_atomic_copy_rejects_hash_mismatch_without_publishing(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "input"
            source.write_bytes(b"corrupt")
            destination = root / "published"
            with self.assertRaises(PREPARE.PreparationError):
                PREPARE.atomic_copy(source, destination, entry(b"approved"))
            self.assertFalse(destination.exists())
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["input"])

    def test_atomic_copy_preserves_existing_unrelated_data(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "input"
            destination = root / "published"
            source.write_bytes(b"approved")
            destination.write_bytes(b"different")
            with self.assertRaises(PREPARE.PreparationError):
                PREPARE.atomic_copy(source, destination, entry(b"approved"))
            self.assertEqual(destination.read_bytes(), b"different")

    def test_source_cache_build_is_offline_and_hash_checked(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            cache = root / "cache"
            cache.mkdir()
            (cache / "source.tar.gz").write_bytes(b"pinned")
            package = {"sources": [{"name": "source.tar.gz", **entry(b"pinned")}]}
            with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")):
                PREPARE.source_archives(root / "install", package, cache, False)
                self.assertEqual((root / "install/downloads/source.tar.gz").read_bytes(), b"pinned")
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.source_archives(root / "missing", package, None, False)

    def test_archive_rejects_traversal_and_symbolic_links(self):
        for member_name, link in [("sdk/../escape", False), ("sdk/file", True)]:
            with self.subTest(member_name=member_name, link=link), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                archive = root / "source.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    member = tarfile.TarInfo(member_name)
                    member.size = 1
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/tmp/untrusted"
                    output.addfile(member, io.BytesIO(b"x") if not link else None)
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.extract_sources(archive, root / "source", entry(archive.read_bytes()))
                self.assertFalse((root / "escape").exists())

    def test_failed_model_install_has_no_ready_directory(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            package = {"modelFiles": [{"installedPath": "weights", "path": "weights", **entry(b"correct")} ]}

            def bad_download(manifest, destination, cache, model, allow_network):
                destination.write_bytes(b"corrupt")

            with patch.object(PREPARE, "download_file", side_effect=bad_download):
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.install_model(root, package, None)
            self.assertFalse((root / "model").exists())
            self.assertEqual(list(root.iterdir()), [])

    def test_checked_in_package_and_model_manifest_match(self):
        package = json.loads((PREPARE.TOOLS / "evaluation-package.json").read_text())
        self.assertEqual(PREPARE.digest(PREPARE.TOOLS / "evaluation-package.json")[1], PREPARE.EXPECTED_PACKAGE_SHA256)
        for filename, metadata in package["buildInputs"].items():
            PREPARE.verify(PREPARE.TOOLS / filename, metadata)
        self.assertEqual(PREPARE.digest(PREPARE.TOOLS / "model-manifest.json")[1], package["modelManifestSHA256"])
        self.assertEqual(len(package["modelFiles"]), 14)
        self.assertEqual(sum(metadata["bytes"] for metadata in package["modelFiles"]), 2134252439)

    def test_offline_model_install_never_attempts_network(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            package = {"modelFiles": [{"installedPath": "weights", "path": "weights", **entry(b"correct")} ]}
            with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network")):
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.install_model(root, package, None, False)
            self.assertFalse((root / "model").exists())

    def test_failed_build_never_publishes_helper_or_receipt(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "downloads").mkdir()
            archive = root / "downloads/sdk.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo("sdk/file.cpp")
                member.size = 1
                output.addfile(member, io.BytesIO(b"x"))
            package = {"sources": [{"name": "sdk.tar.gz", "destination": "source", **entry(archive.read_bytes())}]}
            with patch.object(PREPARE.subprocess, "check_output", return_value="/fake/toolchain"), \
                    patch.object(PREPARE, "run_checked", side_effect=PREPARE.PreparationError("build-failed")):
                with self.assertRaises(PREPARE.PreparationError):
                    PREPARE.build_helper(root, package, sys.executable, {}, None)
            self.assertFalse((root / "evaluation-helper-current").exists())
            self.assertFalse((root / "evaluation-installation.json").exists())
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["downloads"])

    def test_configuration_file_and_canonical_hashes_are_distinct_and_verified(self):
        package = json.loads((PREPARE.TOOLS / "evaluation-package.json").read_text())
        path = PREPARE.TOOLS / "unbatched-configuration.json"
        canonical = json.dumps(json.loads(path.read_text()), sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(canonical).hexdigest(), package["configurationSHA256"])
        self.assertEqual(PREPARE.digest(path)[1], package["buildInputs"][path.name]["sha256"])
        self.assertNotEqual(PREPARE.digest(path)[1], package["configurationSHA256"])


if __name__ == "__main__":
    unittest.main()

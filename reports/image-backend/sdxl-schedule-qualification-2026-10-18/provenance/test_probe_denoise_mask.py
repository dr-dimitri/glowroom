"""Offline failure boundaries for the separate no-op diagnosis runner."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("sdxl_mask_noop_probe", Path(__file__).with_name("probe_denoise_mask.py"))
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class DenoiseMaskProbeTests(unittest.TestCase):
    def test_existing_evidence_is_preserved_before_archive_access(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "evidence"
            output.mkdir(); (output / "keep").write_bytes(b"existing evidence")
            with mock.patch.object(PROBE.BUILDER.PREPARATION, "verify") as verify:
                with self.assertRaisesRegex(PROBE.PreparationError, "new absolute directory"):
                    PROBE.run_probe(Path(folder) / "missing", output)
            verify.assert_not_called()
            self.assertEqual((output / "keep").read_bytes(), b"existing evidence")

    def test_unverified_archive_never_runs_compiler_or_creates_output(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            cache = parent / "cache"; cache.mkdir()
            archive = cache / PROBE.BUILDER.SOURCES[0]["name"]
            archive.write_bytes(b"not pinned")
            output = parent / "evidence"
            with mock.patch.object(PROBE.BUILDER.PREPARATION, "run_checked") as compiler:
                with self.assertRaises(PROBE.PreparationError):
                    PROBE.run_probe(cache, output)
            compiler.assert_not_called()
            self.assertFalse(output.exists())
            self.assertEqual(archive.read_bytes(), b"not pinned")

    def test_changed_source_contract_cannot_support_noop_claim(self):
        with self.assertRaisesRegex(PROBE.PreparationError, "source contract"):
            PROBE.verify_source_contract({"src/pipeline/image.cpp": b"changed max-pool",
                                          "src/pipeline/diffusion_engine.cpp": b"changed selector"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Small synthetic offline regressions; no real weights or native claims."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('registry', Path(__file__).with_name('registry.py'))
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.cards = r.load_cards()

    def card(self, kind):
        return copy.deepcopy(next(c for c in self.cards if c['package']['kind'] == kind))

    def test_all_six_model_families_and_generated_contracts(self):
        self.assertEqual({c['package']['kind'] for c in self.cards},
                         {'semantic-json', 'subject-json', 'llm-swift', 'sky-swift', 'skyseg-swift', 'user-import'})
        r.check_generated(self.cards)
        self.assertEqual(r.outputs(self.cards), r.outputs(list(reversed(self.cards))))

    def test_generation_is_idempotent_and_detects_manual_drift(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            for path in r.outputs(self.cards):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
            r.check_generated(self.cards, root, write=True)
            first = {p: (root / p).read_bytes() for p in r.outputs(self.cards)}
            r.check_generated(self.cards, root, write=True)
            self.assertEqual(first, {p: (root / p).read_bytes() for p in first})
            (root / r.GENERATED).write_text('// manual mutation')
            with self.assertRaisesRegex(r.RegistryError, 'generated file drift'):
                r.check_generated(self.cards, root)

    def test_repair_download_preserves_recorded_bytes_and_manual_import_scope(self):
        c = self.card('user-import')
        self.assertEqual(c['status'], 'download-and-user-import')
        self.assertEqual(c['package']['folder'], 'LaMa.mlpackage')
        self.assertEqual(len(r.inventory(c)), 3)
        self.assertEqual(sum(file['bytes'] for file in r.inventory(c)), 216_647_386)
        self.assertEqual(len(c['package']['referenceFiles']), 4)
        generated = r.outputs(self.cards)[r.GENERATED].decode()
        self.assertIn('static let repairRevision = "5ed76e3799ab4cad31381750d29880c267477e18"', generated)
        self.assertIn('static let repairRepository = "mlboydaisuke/LaMa-CoreML"', generated)
        self.assertIn('static let repairFiles: [SemanticManifestFile]', generated)
        self.assertNotIn('path: "LaMa.mlpackage/', generated)
        for mutate in [lambda card: card['package']['files'][0].update(sha256='0' * 64),
                       lambda card: card['package'].update(folder='Another.mlpackage'),
                       lambda card: card.update(status='app-pinned'),
                       lambda card: card['package']['files'].append(dict(path='extra.bin', bytes=1, sha256='0' * 64))]:
            with self.subTest(mutation=mutate):
                bad = copy.deepcopy(c)
                mutate(bad)
                with self.assertRaises(r.RegistryError):
                    r.validate_card(bad)

    def test_missing_fields_unknown_fields_and_invalid_hashes_fail(self):
        for mutate in [lambda c: c.pop('trainingData'), lambda c: c.update(unexpected=True),
                       lambda c: c['source'].update(revision='main'),
                       lambda c: c['source']['originalWeights'].update(sha256='invalid'),
                       lambda c: c.update(schemaVersion=True),
                       lambda c: c['package']['files'][0].update(sha256='x' * 64),
                       lambda c: c['package']['files'][0].update(bytes=True),
                       lambda c: c['conversion'].update(tools={})]:
            with self.subTest(mutation=mutate):
                c = self.card('llm-swift')
                mutate(c)
                with self.assertRaises(r.RegistryError):
                    r.validate_card(c)

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / 'bad.json'
            path.write_text('{"schemaVersion": 1, "schemaVersion": 2}')
            with self.assertRaisesRegex(r.RegistryError, 'duplicate JSON key'):
                r.read_json(path)

    def test_missing_provenance_and_runtime_conflicts_fail(self):
        c = self.card('semantic-json')
        for field, value in [('dimension', 512), ('maximumTextTokens', 77), ('tokenizerVersion', 'wrong'),
                             ('sourceRevision', '0' * 40)]:
            bad = copy.deepcopy(c)
            bad['package']['approval']['descriptor'][field] = value
            with self.assertRaises(r.RegistryError):
                r.validate_card(bad)
        c['qualification']['reports'] = ['missing-model-source.md']
        with self.assertRaisesRegex(r.RegistryError, 'missing provenance'):
            r.validate_card(c)
        c = self.card('skyseg-swift')
        c['runtime']['engine'] = 'CoreML'
        with self.assertRaises(r.RegistryError):
            r.validate_card(c)

    def test_model_references_must_be_registered_and_identities_unique(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            shutil.copytree(r.REGISTRY / 'cards', directory / 'cards')
            shutil.copy(r.REGISTRY / 'registry.json', directory / 'registry.json')
            registry = r.read_json(directory / 'registry.json')
            extra = directory / 'cards' / 'extra.json'
            extra.write_bytes((directory / registry['cards'][0]).read_bytes())
            with self.assertRaisesRegex(r.RegistryError, 'unregistered'):
                r.load_cards(directory=directory)
            registry['cards'].append('cards/extra.json')
            (directory / 'registry.json').write_bytes(r.canonical(registry))
            with self.assertRaisesRegex(r.RegistryError, 'duplicate model identity'):
                r.load_cards(directory=directory)

    def test_package_paths_duplicates_and_missing_inventory_fail(self):
        for path in ['../weights', '/weights', 'a/../weights', 'a\\weights', './weights', '']:
            with self.subTest(path=path), self.assertRaises(r.RegistryError):
                r.relative(path)
        c = self.card('llm-swift')
        c['package']['files'].append(c['package']['files'][0])
        with self.assertRaisesRegex(r.RegistryError, 'duplicate file path'):
            r.validate_card(c)
        c['package']['files'] = []
        with self.assertRaises(r.RegistryError):
            r.validate_card(c)

    def fixture(self, directory):
        c = self.card('llm-swift')
        payload = b'synthetic fixture weights - never a real model'
        (directory / 'model.bin').write_bytes(payload)
        c['package']['files'] = [dict(path='model.bin', bytes=len(payload), sha256=r.digest(payload))]
        c['source']['originalWeights']['sha256'] = r.digest(payload)
        c['source']['originalWeights']['revision'] = '1' * 40
        return c

    def test_artifacts_bind_entire_tree_size_and_hash(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            c = self.fixture(root)
            r.verify_artifacts(c, root)
            (root / 'extra').write_bytes(b'extra')
            with self.assertRaisesRegex(r.RegistryError, 'missing or additional'):
                r.verify_artifacts(c, root)
            (root / 'extra').unlink()
            original = (root / 'model.bin').read_bytes()
            (root / 'model.bin').write_bytes(b'x' * len(original))
            with self.assertRaisesRegex(r.RegistryError, 'hash/change mismatch'):
                r.verify_artifacts(c, root)
            (root / 'model.bin').unlink()
            with self.assertRaisesRegex(r.RegistryError, 'missing or additional'):
                r.verify_artifacts(c, root)

    def test_earlier_artifact_cannot_change_during_later_hash(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            c = self.fixture(root)
            (root / 'model.bin').rename(root / 'a.bin')
            payload = b'second synthetic file'
            (root / 'b.bin').write_bytes(payload)
            c['package']['files'][0]['path'] = 'a.bin'
            c['package']['files'].append(dict(path='b.bin', bytes=len(payload), sha256=r.digest(payload)))
            real_open = r.os.open
            def changing_open(path, flags, *args, **kwargs):
                if Path(path).name == 'b.bin':
                    (root / 'a.bin').write_bytes(b'x' * (root / 'a.bin').stat().st_size)
                return real_open(path, flags, *args, **kwargs)
            with patch.object(r.os, 'open', side_effect=changing_open):
                with self.assertRaisesRegex(r.RegistryError, 'tree changed'):
                    r.verify_artifacts(c, root, jobs=1)

    def test_unknown_provenance_does_not_requalify_release(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            c = self.fixture(root)
            c['source']['originalWeights']['sha256'] = 'unknown'
            with self.assertRaisesRegex(r.RegistryError, 'original weight provenance'):
                r.release_check(c, self.report(c), root)
            c['source']['originalWeights']['sha256'] = 'x'
            with self.assertRaisesRegex(r.RegistryError, 'original weight provenance'):
                r.release_check(c, self.report(c), root)
            c['source']['originalWeights']['sha256'] = '0' * 64
            c['source']['originalWeights']['revision'] = 'main'
            with self.assertRaisesRegex(r.RegistryError, 'original revision provenance'):
                r.release_check(c, self.report(c), root)
            c['source']['originalWeights']['revision'] = '1' * 40
            c['conversion']['tools']['upstream-converter'] = 'unknown'
            with self.assertRaisesRegex(r.RegistryError, 'conversion tool provenance'):
                r.release_check(c, self.report(c), root)

    def test_symlinks_and_hardlinks_fail(self):
        import os
        with tempfile.TemporaryDirectory() as name:
            root = Path(name) / 'tree'
            root.mkdir()
            c = self.fixture(root)
            original = root.parent / 'original'
            (root / 'model.bin').rename(original)
            (root / 'model.bin').symlink_to(original)
            with self.assertRaisesRegex(r.RegistryError, 'symlink'):
                r.verify_artifacts(c, root)
            (root / 'model.bin').unlink()
            os.link(original, root / 'model.bin')
            with self.assertRaisesRegex(r.RegistryError, 'file type/size'):
                r.verify_artifacts(c, root)

    def report(self, card):
        return dict(schemaVersion=1, modelID=card['identity'], cardSHA256=r.digest(r.canonical(card)),
                    packageSHA256=r.digest(r.canonical(r.inventory(card))), contractSHA256=r.digest(r.canonical(card['contract'])),
                    platform=dict(system='Darwin', macOS='synthetic test only', hardware='synthetic test only'),
                    runtime=dict(engine='MLX', requestedComputePolicy='Metal', observedExecutionPath='synthetic test only', observationMethod='test fixture'),
                    fallback=dict(policy='understandable-error', result='synthetic missing-GPU error case'),
                    checks=dict(load=True, inputsOutputs=True, referenceComparison=True, fallbackOrUnderstandableError=True),
                    reference=dict(method='synthetic test reference', fixtureSHA256='0' * 64, thresholds='test fixture only', result='synthetic test pass', passed=True),
                    measurementIsolation='one-native-model-process-no-concurrent-GPU-work',
                    measurements=[dict(cacheState=state, elapsedSeconds=1.0, peakResidentBytes=1,
                                       cachePreparation='test fixture only; no native inference', executionPath='synthetic')
                                  for state in ['process-first', 'model-warm']], limitations=['synthetic test only'])

    def test_native_gate_needs_exact_identity_all_checks_and_first_warm(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            c = self.fixture(root)
            report = self.report(c)
            self.assertFalse(r.release_check(c, report, root)['automaticAppApproval'])
            mutations = [lambda q: q.update(modelID='other'), lambda q: q.update(cardSHA256='0' * 64),
                         lambda q: q['platform'].update(system='Linux'), lambda q: q['checks'].update(load=False),
                         lambda q: q['checks'].pop('referenceComparison'), lambda q: q['reference'].update(passed=False),
                         lambda q: q.update(measurements=q['measurements'][:1]),
                         lambda q: q['fallback'].update(policy='cpuOnly'), lambda q: q.update(measurementIsolation='parallel')]
            for mutate in mutations:
                q = copy.deepcopy(report)
                mutate(q)
                with self.subTest(mutation=mutate), self.assertRaises(r.RegistryError):
                    r.release_check(c, q, root)

    def test_native_series_lock_rejects_overlap(self):
        with r.native_lock():
            with self.assertRaisesRegex(r.RegistryError, 'another native qualification'):
                with r.native_lock():
                    self.fail('overlapping native series')

    def test_compatibility_reference_is_not_a_release(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            c = self.fixture(root)
            for status in ['user-import', 'download-and-user-import']:
                c['status'] = status
                with self.subTest(status=status), self.assertRaisesRegex(r.RegistryError, 'not a releasable'):
                    r.release_check(c, self.report(c), root)


if __name__ == '__main__':
    unittest.main()

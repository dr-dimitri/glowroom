#!/usr/bin/env python3
"""Offline model registry, deterministic generation, artifact checks and native gates.

Standard library only. It never retrieves models or changes an app installation.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = Path(__file__).resolve().parent
GENERATED = 'Sources/Glowroom/AI/GeneratedLocalModelRegistry.swift'


class RegistryError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise RegistryError(message)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f'{path}: duplicate JSON key {key}')
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(RegistryError('nonfinite JSON: ' + value)))


def schema_check(value, schema, where='card'):
    """Validate the deliberately small published schema vocabulary without pip."""
    if 'type' in schema:
        valid = {'object': isinstance(value, dict), 'array': isinstance(value, list),
                 'string': isinstance(value, str), 'integer': type(value) is int,
                 'number': type(value) in (int, float), 'boolean': type(value) is bool}
        allowed = schema['type'] if isinstance(schema['type'], list) else [schema['type']]
        require(any(valid.get(t, False) for t in allowed), f'{where}: expected {allowed}')
    if 'const' in schema:
        require(type(value) is type(schema['const']) and value == schema['const'], f'{where}: invalid constant')
    if 'enum' in schema:
        require(value in schema['enum'], f'{where}: invalid enum')
    if isinstance(value, dict):
        for field in schema.get('required', []):
            require(field in value, f'{where}: missing {field}')
        require(len(value) >= schema.get('minProperties', 0), f'{where}: too few properties')
        properties = schema.get('properties', {})
        if schema.get('additionalProperties') is False:
            require(not set(value) - set(properties), f'{where}: unknown fields {set(value) - set(properties)}')
        for key, item in value.items():
            child = properties.get(key, schema.get('additionalProperties', {}))
            if isinstance(child, dict):
                schema_check(item, child, where + '.' + key)
    if isinstance(value, list):
        require(len(value) >= schema.get('minItems', 0), f'{where}: too few items')
        if schema.get('uniqueItems'):
            require(len({json.dumps(x, sort_keys=True) for x in value}) == len(value), f'{where}: duplicates')
        for index, item in enumerate(value):
            schema_check(item, schema.get('items', {}), f'{where}[{index}]')
    if isinstance(value, str):
        require(len(value.strip()) >= schema.get('minLength', 0), f'{where}: empty string')
        if 'pattern' in schema:
            require(re.fullmatch(schema['pattern'], value) is not None, f'{where}: invalid format')
    if type(value) in (int, float) and 'minimum' in schema:
        require(value >= schema['minimum'], f'{where}: below minimum')


def relative(value):
    path = PurePosixPath(value)
    require(value and not path.is_absolute() and str(path) == value and '..' not in path.parts
            and '\\' not in value and '\x00' not in value, f'unsafe relative path: {value!r}')
    return path


def inventory(card):
    package = card['package']
    return package.get('approval', {}).get('files', package.get('files', package.get('referenceFiles', [])))


def validate_card(card, root=ROOT):
    schema_check(card, read_json(REGISTRY / 'card.schema.json'))
    require(re.fullmatch('[a-z0-9][a-z0-9-]+', card['identity']), 'invalid model identity')
    require(re.fullmatch('[a-f0-9]{40}', card['source']['revision']), 'source revision must be immutable')
    seen = set()
    for file in inventory(card):
        schema_check(file, read_json(REGISTRY / 'file.schema.json'))
        relative(file['path'])
        require(file['path'] not in seen, 'duplicate file path')
        seen.add(file['path'])
    require(seen, 'missing release inventory')
    for ref in [*card['qualification']['reports'], card['conversion']['evidence'],
                card['trainingData']['evidence'], card['licenses']['code']['evidence'], card['licenses']['weights']['evidence']]:
        relative(ref)
        require((root / ref).is_file(), 'missing provenance cross-reference: ' + ref)
    pkg, contract = card['package'], card['contract']
    kind = pkg['kind']
    expected_policy = {'semantic-json': 'cpuOnly', 'subject-json': 'cpuAndGPU', 'sky-swift': 'all', 'skyseg-swift': 'none', 'llm-swift': 'Metal', 'user-import': 'all'}
    require(card['runtime']['computePolicy'] == expected_policy[kind], 'compute policy contradicts app adapter')
    if kind == 'semantic-json':
        require(contract['resolution'] == [256, 256], 'semantic preprocessing requires 256 square')
        desc = pkg['approval']['descriptor']
        require(desc['releaseID'] == card['identity'] and desc['modelID'] == card['source']['repository']
                and desc['sourceRevision'] == card['source']['revision'], 'semantic identity mismatch')
        require(desc['dimension'] == 768 and desc['maximumTextTokens'] == 64, 'semantic adapter requires 768 features / 64 tokens')
        require(contract['inputs'][0]['dtype'] == 'float32' and contract['inputs'][1]['dtype'] == 'int32' and contract['outputs'][0]['dtype'] == 'float32', 'semantic tensor dtype mismatch')
        require(contract['inputs'][0]['shape'] == [1, 3, *contract['resolution']]
                and contract['inputs'][1]['shape'] == [1, desc['maximumTextTokens']]
                and contract['outputs'][0]['shape'] == [1, desc['dimension']]
                and card['runtime']['computePolicy'] == 'cpuOnly', 'semantic runtime contract mismatch')
        require(desc['tokenizerVersion'] in contract['tokenizerOrPrompt'], 'tokenizer contract mismatch')
    elif kind == 'subject-json':
        approval = pkg['approval']
        side = contract['resolution'][0]
        require(approval['sourceRevision'] == card['source']['revision']
                and approval['weightsSHA256'] == card['source']['originalWeights']['sha256']
                and contract['resolution'] == [side, side]
                and contract['inputs'][0]['shape'] == [side, side]
                and contract['outputs'][0]['shape'] == [1, 1, side, side], 'subject runtime contract mismatch')
    elif kind == 'sky-swift':
        require(contract['resolution'] == [448, 448] and contract['outputs'][0]['dtype'] == 'int32', 'sky raster converter contract mismatch')
        require(contract['inputs'][0]['shape'] == contract['resolution']
                and contract['outputs'][0]['shape'] == contract['resolution'], 'sky runtime contract mismatch')
    require(card['runtime']['engine'] == ('MLX' if kind == 'llm-swift' else 'none-download-only' if kind == 'skyseg-swift' else 'CoreML'), 'runtime engine contradicts family')
    if kind == 'llm-swift':
        require({'chat_template.jinja', 'config.json', 'model.safetensors', 'tokenizer.json', 'tokenizer_config.json', 'preprocessor_config.json', 'processor_config.json'} <= seen, 'missing LLM processor/tokenizer/weights')
        require(card['runtime']['computePolicy'] == 'Metal' and card['runtime']['fallback'] == 'understandable-error', 'unqualified MLX fallback')
    if kind == 'skyseg-swift':
        require(card['status'] == 'download-only' and card['runtime']['engine'] == 'none-download-only',
                'Skyseg must remain download-only')
    if kind == 'user-import':
        require(card['status'] == 'download-and-user-import', 'repair download and user imports are not global generation approvals')
        require(pkg.get('folder') == 'LaMa.mlpackage', 'repair download package folder mismatch')
        require(set(seen) == {'Manifest.json', 'Data/com.apple.CoreML/model.mlmodel',
                              'Data/com.apple.CoreML/weights/weight.bin'}, 'repair download inventory mismatch')
        reference = {file['path']: file for file in pkg.get('referenceFiles', [])}
        for file in inventory(card):
            recorded = reference.get(pkg['folder'] + '/' + file['path'])
            require(recorded == dict(file, path=pkg['folder'] + '/' + file['path']),
                    'repair download differs from recorded evaluation bytes')
    if kind in ('semantic-json', 'subject-json'):
        relative(pkg['target'])
        require(pkg['target'].startswith('Sources/Glowroom/AI/Resources/'), 'invalid generated resource target')
    for binding in card['bindings']:
        relative(binding['path'])
        require(binding['contains'] in (root / binding['path']).read_text(), 'runtime source drift: ' + binding['path'])


def load_cards(root=ROOT, directory=REGISTRY, jobs=2):
    registry = read_json(directory / 'registry.json')
    require(registry.get('schemaVersion') == 1 and isinstance(registry.get('cards'), list), 'invalid registry')
    require(len(set(registry['cards'])) == len(registry['cards']), 'duplicate card reference')
    paths = [directory / relative(name) for name in registry['cards']]
    require(set(paths) == set((directory / 'cards').glob('*.json')), 'unregistered or missing model card')
    def prepare(path):
        card = read_json(path)
        validate_card(card, root)
        return card
    # Cards and source references are independent; two workers bound metadata I/O.
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        cards = list(executor.map(prepare, paths))
    require(len({x['identity'] for x in cards}) == len(cards), 'duplicate model identity')
    require(len({x['package']['kind'] for x in cards}) == len(cards), 'duplicate runtime family')
    require({x['package']['kind'] for x in cards} == {'semantic-json', 'subject-json', 'llm-swift', 'sky-swift', 'skyseg-swift', 'user-import'}, 'missing current runtime family')
    return sorted(cards, key=lambda card: card['identity'])


def swift_string(value):
    require('\\' not in value and all(ord(c) >= 32 for c in value), 'unsupported Swift string')
    return json.dumps(value, ensure_ascii=False)


def swift_files(files):
    return ',\n'.join('        .init(path: %s, bytes: %d, sha256: %s)' %
                      (swift_string(f['path']), f['bytes'], swift_string(f['sha256'])) for f in files)


def outputs(cards):
    cards = sorted(cards, key=lambda card: card['identity'])
    lines = ['// Generated by tools/model-registry/registry.py. Do not edit.',
             '// Model cards are developer inputs; runtime approval remains compiled into the app.',
             'import Foundation', 'import GlowroomCore', '', 'enum LocalModelRegistry {']
    for card in cards:
        pkg, source = card['package'], card['source']
        kind = pkg['kind']
        if kind == 'llm-swift':
            lines += [f'    static let qwen35 = LLMModelDescriptor(id: {swift_string(card["identity"])}, name: {swift_string(pkg["name"])},',
                      f'        repository: {swift_string(source["repository"])}, revision: {swift_string(source["revision"])}, files: [',
                      swift_files(inventory(card)), '    ])']
        if kind == 'semantic-json':
            desc = pkg['approval']['descriptor']
            fields = ',\n'.join('        %s: %s' % (key, swift_string(desc[key]) if isinstance(desc[key], str) else desc[key])
                                for key in ['modelID', 'sourceRevision', 'releaseID', 'dimension', 'maximumTextTokens', 'tokenizerVersion', 'preprocessingVersion', 'normalizationVersion'])
            lines += ['    static let semantic = SemanticModelDescriptor(', fields + ')']
        if kind in ('sky-swift', 'skyseg-swift'):
            prefix = 'sky' if kind == 'sky-swift' else 'skyseg'
            lines += [f'    static let {prefix}Revision = {swift_string(source["revision"])}',
                      f'    static let {prefix}Repository = {swift_string(source["repository"])}',
                      f'    static let {prefix}Files: [SemanticManifestFile] = [', swift_files(inventory(card)), '    ]']
            if kind == 'sky-swift':
                lines += [f'    static let skyFolder = {swift_string(pkg["folder"])}', f'    static let skySide = {card["contract"]["resolution"][0]}']
        if kind == 'user-import':
            lines += [f'    static let repairRevision = {swift_string(source["revision"])}',
                      f'    static let repairRepository = {swift_string(source["repository"])}',
                      f'    static let repairFolder = {swift_string(pkg["folder"])}',
                      '    static let repairFiles: [SemanticManifestFile] = [', swift_files(inventory(card)), '    ]']
        if kind == 'subject-json':
            lines += [f'    static let subjectSide = {card["contract"]["resolution"][0]}',
                      f'    static let subjectContract = {swift_string(pkg["approval"]["contract"])}',
                      f'    static let subjectRevision = {swift_string(source["revision"])}',
                      f'    static let subjectWeightsSHA256 = {swift_string(pkg["approval"]["weightsSHA256"])}']
    lines += ['}', '']
    result = {GENERATED: '\n'.join(lines).encode()}
    for card in cards:
        if card['package']['kind'] in ('semantic-json', 'subject-json'):
            result[card['package']['target']] = canonical(card['package']['approval'])
    return result


def check_generated(cards, root=ROOT, write=False):
    for name, expected in outputs(cards).items():
        path = root / name
        if write:
            path.write_bytes(expected)
        else:
            require(path.is_file() and path.read_bytes() == expected, 'generated file drift; run generate: ' + name)


def verify_artifacts(card, directory, jobs=2):
    require(directory.is_dir() and not directory.is_symlink(), 'missing release artifact directory: ' + str(directory))
    expected = {f['path']: f for f in inventory(card)}
    def identity(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    def snapshot():
        files, stamps = set(), {'.': identity(directory.lstat())}
        require(not directory.is_symlink() and directory.is_dir(), 'artifact root changed')
        for path in directory.rglob('*'):
            value = path.lstat()
            name = path.relative_to(directory).as_posix()
            require(not stat.S_ISLNK(value.st_mode), 'symlink artifact: ' + str(path))
            require(stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode), 'special artifact: ' + str(path))
            stamps[name] = identity(value)
            if stat.S_ISREG(value.st_mode):
                files.add(name)
        return files, stamps
    actual, before_tree = snapshot()
    # Portable semantic packages may include their generated manifest. It must
    # itself equal app approval, rather than being trusted as a server manifest.
    if card['package']['kind'] == 'semantic-json' and 'manifest.json' in actual:
        require((directory / 'manifest.json').read_bytes() == canonical(card['package']['approval']), 'unapproved semantic manifest')
        actual.remove('manifest.json')
    require(actual == set(expected), 'missing or additional release artifacts')

    def verify(name):
        path, file = directory / name, expected[name]
        before = path.lstat()
        require(identity(before) == before_tree[name], 'artifact changed before hashing: ' + name)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size == file['bytes'], 'invalid file type/size: ' + name)
        h = hashlib.sha256()
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as handle:
            require(identity(os.fstat(handle.fileno())) == identity(before), 'artifact changed while opening: ' + name)
            while block := handle.read(1024 * 1024):
                h.update(block)
            after = os.fstat(handle.fileno())
        require(identity(before) == identity(after) == identity(path.lstat()) and h.hexdigest() == file['sha256'], 'artifact hash/change mismatch: ' + name)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        list(executor.map(verify, sorted(expected)))
    _, after_tree = snapshot()
    require(before_tree == after_tree, 'artifact tree changed during verification')


def release_check(card, report, artifacts, jobs=2):
    verify_artifacts(card, artifacts, jobs)
    require(card['status'] == 'app-pinned', 'download and user-import statuses are not a releasable app model')
    original = card['source']['originalWeights']
    require(isinstance(original['sha256'], str) and re.fullmatch('[a-f0-9]{64}', original['sha256']) is not None, 'original weight provenance is missing/invalid; new release blocked')
    require(isinstance(original['revision'], str) and re.fullmatch('[a-f0-9]{40}', original['revision']) is not None, 'original revision provenance is missing/invalid; new release blocked')
    require(all(version != 'unknown' for version in card['conversion']['tools'].values()), 'conversion tool provenance is missing; new release blocked')
    schema_check(report, read_json(REGISTRY / 'native-evidence.schema.json'), 'native evidence')
    require(report['modelID'] == card['identity'] and report['cardSHA256'] == digest(canonical(card))
            and report['packageSHA256'] == digest(canonical(inventory(card))), 'native evidence identity mismatch')
    require(report['platform']['system'] == 'Darwin', 'native macOS evidence required')
    require(report['runtime']['engine'] == card['runtime']['engine']
            and report['runtime']['requestedComputePolicy'] == card['runtime']['computePolicy'], 'runtime evidence mismatch')
    require(report['fallback']['policy'] == card['runtime']['fallback'], 'fallback evidence mismatch')
    require(all(report['checks'].values()), 'native load/I-O/reference/fallback checks must all pass')
    require(report['reference']['passed'], 'native reference gate failed')
    require(report['measurementIsolation'] == 'one-native-model-process-no-concurrent-GPU-work', 'native series must run isolated')
    require({x['cacheState'] for x in report['measurements']} >= {'process-first', 'model-warm'}, 'first/warm measurements required')
    require(report['contractSHA256'] == digest(canonical(card['contract'])), 'native I/O contract identity mismatch')
    return {'modelID': card['identity'], 'status': 'native-evidence-validated', 'cardSHA256': digest(canonical(card)),
            'limits': report['limitations'], 'automaticAppApproval': False}


@contextlib.contextmanager
def native_lock():
    # A single host-wide developer measurement lock; never remove an active lock.
    lock = Path(tempfile.gettempdir()) / f'glowroom-model-qualification-{os.getuid()}.lock'
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        st = os.fstat(fd)
        require(st.st_uid == os.getuid() and stat.S_ISREG(st.st_mode) and st.st_nlink == 1, 'unsafe native qualification lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RegistryError('another native qualification is active') from error
        yield
    finally:
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'generate', 'release-check', 'native-run'])
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--model', help='card identity for artifact/release checks')
    parser.add_argument('--artifacts-dir', type=Path, help='exact unpacked artifact tree for --model')
    parser.add_argument('--evidence', type=Path, help='native report JSON; native-run requires a new file')
    parser.add_argument('native_command', nargs='*', help='native executable and arguments after --')
    # Native arguments belong to the external harness and may contain options.
    raw = list(argv if argv is not None else sys.argv[1:])
    split = raw.index('--') if '--' in raw else len(raw)
    args = parser.parse_args(raw[:split])
    args.native_command = raw[split + 1:] if split < len(raw) else []
    require(1 <= args.jobs <= 4, '--jobs must be between 1 and 4')
    cards = load_cards(jobs=args.jobs)
    check_generated(cards, write=args.command == 'generate')
    if args.artifacts_dir or args.command in ('release-check', 'native-run'):
        matches = [c for c in cards if c['identity'] == args.model]
        require(len(matches) == 1 and args.artifacts_dir is not None, 'artifact checks require --model and --artifacts-dir')
        card = matches[0]
        verify_artifacts(card, args.artifacts_dir, args.jobs)
    if args.command in ('release-check', 'native-run'):
        require(args.evidence is not None, '--evidence is required')
        with native_lock():
            if args.command == 'native-run':
                require(sys.platform == 'darwin', 'native-run requires macOS')
                require(args.native_command and not args.evidence.exists(), 'supply a native command and new evidence output')
                env = dict(os.environ, GLOWROOM_QUALIFICATION_MODEL_ID=card['identity'],
                           GLOWROOM_QUALIFICATION_CARD_SHA256=digest(canonical(card)),
                           GLOWROOM_QUALIFICATION_PACKAGE_SHA256=digest(canonical(inventory(card))),
                           GLOWROOM_QUALIFICATION_CONTRACT_SHA256=digest(canonical(card['contract'])),
                           GLOWROOM_QUALIFICATION_OUTPUT=str(args.evidence.resolve()),
                           GLOWROOM_QUALIFICATION_ARTIFACTS=str(args.artifacts_dir.resolve()))
                subprocess.run(args.native_command, env=env, check=True)
            text = release_check(card, read_json(args.evidence), args.artifacts_dir, args.jobs)
            print(json.dumps(text, indent=2))
    else:
        print(f'{args.command}: {len(cards)} model families, schema/provenance/contracts/generated outputs valid')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RegistryError, OSError, KeyError, TypeError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f'model-registry: {error}', file=sys.stderr)
        raise SystemExit(1)

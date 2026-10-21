#!/usr/bin/env python3
"""Build the one approved offline import package; no downloader or Python runtime in Glowroom."""
import argparse, concurrent.futures, hashlib, json, pathlib, shutil, tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
RESOURCES = REPO / 'Sources/Glowroom/AI/Resources'
parser = argparse.ArgumentParser()
parser.add_argument('--image', required=True, type=pathlib.Path, help='approved full-Float32 image .mlpackage')
parser.add_argument('--text', required=True, type=pathlib.Path, help='approved Float16 text .mlpackage')
parser.add_argument('--tokenizer', required=True, type=pathlib.Path, help='pinned source directory containing JSON configs')
parser.add_argument('--output', required=True, type=pathlib.Path, help='new portable package directory; never overwritten')
args = parser.parse_args()
manifest_bytes = (RESOURCES / 'SemanticApprovedPackage.json').read_bytes()
manifest = json.loads(manifest_bytes)
if args.output.exists():
    parser.error('output already exists; prior artifacts are never overwritten')
args.output.parent.mkdir(parents=True, exist_ok=True)

def source(file):
    name = file['path']
    if name.startswith('models/image.mlpackage/'):
        return args.image / name.removeprefix('models/image.mlpackage/')
    if name.startswith('models/text.mlpackage/'):
        return args.text / name.removeprefix('models/text.mlpackage/')
    if name.startswith('tokenizer/'):
        return args.tokenizer / name.removeprefix('tokenizer/')
    return RESOURCES / 'SemanticLicenses' / pathlib.Path(name).name

with tempfile.TemporaryDirectory(prefix='.semantic-bundle-', dir=args.output.parent) as temporary:
    stage = pathlib.Path(temporary) / 'payload'
    stage.mkdir()
    def copy(file):
        original = source(file)
        if original.is_symlink() or not original.is_file() or original.stat().st_size != file['bytes']:
            raise ValueError('unapproved file type or size: ' + file['path'])
        destination = stage / file['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        with original.open('rb') as src, destination.open('xb') as dst:
            while block := src.read(1024 * 1024):
                digest.update(block)
                dst.write(block)
        if digest.hexdigest() != file['sha256'] or destination.stat().st_size != file['bytes']:
            raise ValueError('SHA256 differs from application approval: ' + file['path'])
    # Independent files, bounded at two MiB of transfer buffers.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(copy, manifest['files']))
    (stage / 'manifest.json').write_bytes(manifest_bytes)
    stage.rename(args.output)
print(json.dumps({'output': str(args.output), 'source_bytes': sum(f['bytes'] for f in manifest['files']) + len(manifest_bytes),
                  'release': manifest['descriptor']['releaseID'], 'files': len(manifest['files']) + 1}, indent=2))

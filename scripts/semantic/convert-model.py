#!/usr/bin/env python3
"""Offline reproducible export of one approved tower. Developer-only, Python 3.11.

Install torch==2.5.0 transformers==4.51.3 coremltools==8.3 numpy==1.26.4
protobuf==7.36.2 packaging==26.3
in a separate development environment. Supply an already downloaded, pinned
source directory; this script intentionally has no network/download operation.
"""
import os
for key in ['OMP_NUM_THREADS', 'MKL_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS']:
    os.environ[key] = '2'
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
import argparse, gc, hashlib, importlib.metadata, json, pathlib, sys
from packaging.version import Version

parser = argparse.ArgumentParser()
parser.add_argument('--tower', choices=['image', 'text'], required=True)
parser.add_argument('--source', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
if sys.version_info[:2] != (3, 11):
    parser.error('Python 3.11 is required for the pinned export environment')
for package, version in [('torch', '2.5.0'), ('transformers', '4.51.3'), ('coremltools', '8.3'), ('numpy', '1.26.4'), ('protobuf', '7.36.2'), ('packaging', '26.3')]:
    if Version(importlib.metadata.version(package)) != Version(version):
        parser.error(f'{package} must be exactly {version}')
if args.output.exists():
    parser.error('output exists; previous artifacts are never overwritten')

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(1024 * 1024): h.update(block)
    return h.hexdigest()

checkpoint = args.source / 'model.safetensors'
if sha(checkpoint) != '7d241bb3becad218f211f480487f491df4f8c0a472ecf7afdec5615815a301f1':
    parser.error('source checkpoint does not match the pinned Google revision')
resources = pathlib.Path(__file__).resolve().parents[2] / 'Sources/Glowroom/AI/Resources'
manifest = json.loads((resources / 'SemanticApprovedPackage.json').read_bytes())
for file in manifest['files']:
    if file['path'].startswith('tokenizer/'):
        if sha(args.source / pathlib.Path(file['path']).name) != file['sha256']:
            parser.error('pinned source configuration mismatch: ' + file['path'])
import numpy as np
import torch
import coremltools as ct
from transformers import SiglipModel

torch.set_num_threads(2)
torch.set_num_interop_threads(1)
torch.backends.mha.set_fastpath_enabled(False)
full = SiglipModel.from_pretrained(args.source, local_files_only=True, attn_implementation='eager').eval()
class Tower(torch.nn.Module):
    def __init__(self, tower): super().__init__(); self.tower = tower
    def forward(self, x):
        if args.tower == 'image': return self.tower(pixel_values=x, return_dict=False)[1]
        return self.tower(input_ids=x, return_dict=False)[1]
wrapper = Tower(full.vision_model if args.tower == 'image' else full.text_model).eval()
del full
gc.collect()
is_image = args.tower == 'image'
shape = (1, 3, 256, 256) if is_image else (1, 64)
with torch.inference_mode():
    traced = torch.jit.trace(wrapper, torch.zeros(shape, dtype=torch.float32 if is_image else torch.int32), strict=True)
package = ct.convert(traced, convert_to='mlprogram',
    inputs=[ct.TensorType(name='pixels' if is_image else 'input_ids', shape=shape, dtype=np.float32 if is_image else np.int32)],
    outputs=[ct.TensorType(name='embedding', dtype=np.float32)],
    compute_precision=ct.precision.FLOAT32 if is_image else ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14, skip_model_load=True)
# Authorship is embedded in the approved graph bytes; preserve provenance.
package.author = 'Google; PicEdit local Core ML conversion'
package.license = 'Apache-2.0; source model revision 94dffa8cb1179de3e03f091dbc3917e5d5a9ae84'
package.short_description = ('SigLIP2 Base Patch32 256 image encoder; precision diagnostic fp32; L2 externally' if is_image
    else 'SigLIP 2 Base Patch32 256 text encoder; raw 768 features; L2 normalize externally')
package.user_defined_metadata['source_revision'] = '94dffa8cb1179de3e03f091dbc3917e5d5a9ae84'
package.user_defined_metadata['conversion'] = ('torch2.5.0-transformers4.51.3-coremltools8.3-macOS14-fp32-v1' if is_image
    else 'torch2.5.0-transformers4.51.3-coremltools8.3-FP16-macOS14-v1')
package.save(str(args.output))
# Protobuf maps otherwise have process-dependent wire ordering. Preserve every
# field/value and require the one approved deterministic graph representation.
from coremltools.proto import Model_pb2
model_path = args.output / 'Data/com.apple.CoreML/model.mlmodel'
serialized = Model_pb2.Model()
serialized.ParseFromString(model_path.read_bytes())
model_path.write_bytes(serialized.SerializeToString(deterministic=True))
# Core ML package UUIDs are otherwise random. Canonicalize that manifest too,
# then require the canonical graph and every weight byte to equal approval.
(args.output / 'Manifest.json').write_bytes((resources / ('SemanticImagePackageManifest.json' if is_image
    else 'SemanticTextPackageManifest.json')).read_bytes())
prefix = f'models/{args.tower}.mlpackage/'
for file in manifest['files']:
    if file['path'].startswith(prefix):
        path = args.output / file['path'].removeprefix(prefix)
        if path.stat().st_size != file['bytes'] or sha(path) != file['sha256']:
            raise SystemExit('Export differs from approved bytes; do not distribute: ' + str(path))
print('Approved export reproduced:', args.output)

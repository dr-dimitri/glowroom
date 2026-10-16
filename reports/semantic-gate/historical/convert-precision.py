"""Offline precision variants; preserves the pinned source, fixtures and original exports."""
import os
for key in ['OMP_NUM_THREADS','MKL_NUM_THREADS','OPENBLAS_NUM_THREADS','VECLIB_MAXIMUM_THREADS']:
    os.environ[key]='2'
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
import collections,gc,hashlib,json,pathlib,resource,sys,time
import numpy as np
import torch
import coremltools as ct
from transformers import SiglipModel
ROOT=pathlib.Path(__file__).parent
variant=sys.argv[1]
selectors={'ln32':{'layer_norm'},'lnsm32':{'layer_norm','softmax'},'attention32':{'layer_norm','softmax','matmul','mul'},'fp32':set()}
assert variant in selectors
assert hashlib.sha256((ROOT/'ground-truth.json').read_bytes()).hexdigest()=='c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025'
dest=ROOT/('image-'+variant+'.mlpackage')
assert not dest.exists(), 'Never overwrite a previously measured variant'
torch.set_num_threads(2);torch.set_num_interop_threads(1)
torch.backends.mha.set_fastpath_enabled(False)
start=time.perf_counter()
full=SiglipModel.from_pretrained(ROOT/'source',local_files_only=True,attn_implementation='eager').eval()
class Tower(torch.nn.Module):
    def __init__(self,tower): super().__init__();self.tower=tower
    def forward(self,x): return self.tower(pixel_values=x,return_dict=False)[1]
wrapper=Tower(full.vision_model).eval()
del full;gc.collect()
shape=(1,3,256,256)
with torch.inference_mode(): traced=torch.jit.trace(wrapper,torch.zeros(shape,dtype=torch.float32),strict=True)
selected=[]
def selector(op):
    use_half=op.op_type not in selectors[variant]
    if not use_half: selected.append({'name':op.name,'type':op.op_type})
    return use_half
precision=ct.precision.FLOAT32 if variant=='fp32' else ct.transform.FP16ComputePrecision(op_selector=selector)
package=ct.convert(traced,convert_to='mlprogram',inputs=[ct.TensorType(name='pixels',shape=shape,dtype=np.float32)],outputs=[ct.TensorType(name='embedding',dtype=np.float32)],compute_precision=precision,minimum_deployment_target=ct.target.macOS14,skip_model_load=True)
package.author='Google; PicEdit local Core ML conversion'
package.license='Apache-2.0; source model revision 94dffa8cb1179de3e03f091dbc3917e5d5a9ae84'
package.short_description=f'SigLIP2 Base Patch32 256 image encoder; precision diagnostic {variant}; L2 externally'
package.user_defined_metadata['source_revision']='94dffa8cb1179de3e03f091dbc3917e5d5a9ae84'
package.user_defined_metadata['conversion']='torch2.5.0-transformers4.51.3-coremltools8.3-macOS14-'+variant+'-v1'
package.save(str(dest))
files=[]
for p in sorted(dest.rglob('*')):
    if p.is_file(): files.append({'path':str(p.relative_to(ROOT)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
block=next(iter(package.get_spec().mlProgram.functions['main'].block_specializations.values()))
ops=collections.Counter(o.type for o in block.operations)
result={'variant':variant,'seconds':time.perf_counter()-start,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'bytes':sum(f['bytes'] for f in files),'files':files,'float32_operations':selected,'operation_counts':ops,'ground_truth_sha256':hashlib.sha256((ROOT/'ground-truth.json').read_bytes()).hexdigest()}
(ROOT/('image-'+variant+'-conversion.json')).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['files','float32_operations']}),flush=True)

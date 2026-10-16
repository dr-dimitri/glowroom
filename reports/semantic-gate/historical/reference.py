import os
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
import hashlib,json,pathlib,time,resource
import numpy as np
from PIL import Image
import torch
from transformers import AutoTokenizer, SiglipImageProcessor, SiglipModel

ROOT=pathlib.Path(__file__).parent
SOURCE=ROOT/'source'
torch.set_num_threads(2)
torch.set_num_interop_threads(1)
truthbytes=(ROOT/'ground-truth.json').read_bytes()
assert hashlib.sha256(truthbytes).hexdigest()=='c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025'
truth=json.loads(truthbytes)
tokenizer=AutoTokenizer.from_pretrained(SOURCE,local_files_only=True,use_fast=True)
processor=SiglipImageProcessor.from_pretrained(SOURCE,local_files_only=True)
start=time.perf_counter()
model=SiglipModel.from_pretrained(SOURCE,local_files_only=True,attn_implementation='eager').eval()
load=time.perf_counter()-start
def ids(text):
    return tokenizer(text.lower(),padding='max_length',max_length=64,truncation=True,return_tensors='pt')['input_ids']
def normalized(value):
    value=value.float()
    return (value/value.norm(dim=-1,keepdim=True)).cpu().numpy()[0]
imagevec=[];textvec=[];rows=[];timings=[]
with torch.inference_mode():
    for asset in truth['assets']:
        path=ROOT/asset['path']
        assert hashlib.sha256(path.read_bytes()).hexdigest()==asset['png_sha256']
        image=Image.open(path).convert('RGB')
        assert hashlib.sha256(image.tobytes()).hexdigest()==asset['rgb_sha256']
        pixel=processor(images=image,return_tensors='pt')['pixel_values']
        pixel.numpy().astype('<f4').tofile(ROOT/(asset['id']+'-input.f32'))
        start=time.perf_counter(); v=normalized(model.get_image_features(pixel)); timings.append(time.perf_counter()-start)
        imagevec.append(v)
    imagevec=np.stack(imagevec)
    negative=[dict(q,id=f'negative-{i+1:02}') for i,q in enumerate(truth['negative_queries'])]
    for q in truth['queries']+negative:
        for lang in ['de','en']:
            start=time.perf_counter(); token=ids(q[lang]); v=normalized(model.get_text_features(input_ids=token)); dt=time.perf_counter()-start
            scores=imagevec@v
            order=sorted(range(len(scores)),key=lambda i:(-float(scores[i]),truth['assets'][i]['id']))
            ranked=[truth['assets'][i]['id'] for i in order]
            rows.append({'id':q['id'],'language':lang,'text':q[lang],'input_ids':token[0].tolist(),'seconds':dt,'ranking':[{'asset':truth['assets'][i]['id'],'score':float(scores[i])} for i in order], 'hit_top5':any(x in ranked[:5] for x in q.get('relevant_asset_ids',[]))})
            textvec.append(v)
    golden=['Äpfel, Öl & Straße!','A BLUE house.','  mehrere\tLeerzeichen\n','café cafe\u0301','İstanbul 😀','<bos> red <eos>','ein Haus '*100,'']
    tokens=[{'text':x,'normalized':x.lower(),'input_ids':ids(x)[0].tolist()} for x in golden]
np.stack(imagevec).astype('<f4').tofile(ROOT/'reference-images.f32')
np.stack(textvec).astype('<f4').tofile(ROOT/'reference-queries.f32')
(ROOT/'token-golden.json').write_text(json.dumps(tokens,ensure_ascii=False,indent=2)+'\n')
summary={lang:sum(r['hit_top5'] for r in rows if r['language']==lang and r['id'].startswith('q-'))/20 for lang in ['de','en']}
out={'model':'google/siglip2-base-patch32-256','revision':'94dffa8cb1179de3e03f091dbc3917e5d5a9ae84','runtime':'torch 2.5.0 CPU, eager, 2 threads','tokenizer':'transformers 4.51.3 fast, lowercase, right-pad 64, EOS; no attention mask','ground_truth_sha256':hashlib.sha256(truthbytes).hexdigest(),'load_seconds':load,'image_seconds':timings,'quality':summary,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'rows':rows}
(ROOT/'reference-results.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in out.items() if k not in ['rows','image_seconds']},ensure_ascii=False),flush=True)

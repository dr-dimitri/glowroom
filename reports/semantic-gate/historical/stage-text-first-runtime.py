from pathlib import Path
import shutil,hashlib,json,subprocess,uuid
r=Path(__file__).parent;a=r/'runtime-fp32-isolated-text-first';build=r/'native-fp32-isolated-build/release'
shutil.copy2(build/'SemanticFP32Gate',a/'SemanticFP32Gate')
for item in build.glob('*.bundle'):shutil.copytree(item,a/item.name,dirs_exist_ok=True)
def signatures(root):
 out=[]
 for p in sorted(root.rglob('*')):
  if p.is_file() and p.name!='runtime-manifest.json':
   h=hashlib.sha256()
   with p.open('rb') as f:
    while data:=f.read(1024*1024):h.update(data)
   out.append(dict(path=str(p.relative_to(root)),bytes=p.stat().st_size,sha256=h.hexdigest()))
 return out
files=signatures(a)
fresh=r/('runtime-fp32-text-first-'+str(uuid.uuid4()))
subprocess.run(['/bin/cp','-cR',str(a),str(fresh)],check=True)
assert signatures(fresh)==files
manifest=dict(version=2,active_representation='compiled CoreML only; no package/checkpoint/SentencePiece duplicate',files=files,bytes_excluding_this_manifest=sum(f['bytes'] for f in files),manifest_self_excluded_from_hash_list=True,ground_truth_sha256=hashlib.sha256((r/'ground-truth.json').read_bytes()).hexdigest(),fresh_installation_path=str(fresh),clone_payload_matches_template=True,cache_state='new UUID APFS-cloned path; process/app caches empty; OS/CoreML caches uncontrolled and already used; no cache purge')
(fresh/'runtime-manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
(r/'text-first-runtime-path.txt').write_text(str(fresh)+'\n')
print(fresh)
print('bytes incl manifest',sum(p.stat().st_size for p in fresh.rglob('*') if p.is_file()))

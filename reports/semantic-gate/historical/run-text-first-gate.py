from pathlib import Path
import os,re,subprocess,sys
r=Path(__file__).parent;runtime=Path((r/'text-first-runtime-path.txt').read_text().strip());mode=sys.argv[1]
assert mode in ['all','cpu']
tag=sys.argv[2] if len(sys.argv)>2 else ''
assert not tag or re.fullmatch(r'[A-Za-z0-9_-]+',tag)
name='native-fp32-isolated-text-first-per-model-pool-'+mode+('-'+tag if tag else '')
assert not (r/(name+'-results.json')).exists()
env=os.environ.copy()
for key in ['VECLIB_MAXIMUM_THREADS','OMP_NUM_THREADS','OPENBLAS_NUM_THREADS']:env[key]='2'
with (r/(name+'.log')).open('x') as output:
 result=subprocess.run(['/usr/bin/time','-lp',str(runtime/'SemanticFP32Gate'),mode,'--lifecycle','text-first-per-model-pool','--runtime',str(runtime),'--output',name+'-results.json'],stdout=output,stderr=subprocess.STDOUT,env=env)
print('finished',mode,'exit',result.returncode)
sys.exit(result.returncode)

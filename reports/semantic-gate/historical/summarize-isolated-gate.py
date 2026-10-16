from pathlib import Path
import json,re
r=Path(__file__).parent
names=['tokenizer-first-all','tokenizer-first-cpu','models-first-pool-all','text-first-per-model-pool-all','text-first-per-model-pool-cpu']
rows=[]
keys=['gates','all_gates_passed','baseline_peak_rss_bytes','baseline_resident_rss_bytes','peak_rss_bytes','extra_peak_rss_bytes','runtime_files_bytes','tokenizer_load_seconds','model_load_seconds','warm_full_query_p50_seconds','warm_full_query_p95_seconds','cached_query_p50_seconds','cached_query_p95_seconds','search_p50_seconds','search_p95_seconds','image_index_images_per_second','image_index_warm_images_per_second','quality_top5_hits_each_of20','cache_state']
for name in names:
 p=r/('native-fp32-isolated-'+name+'-results.json');data=json.loads(p.read_text());row={key:data[key] for key in keys};row['run']=name
 row['maximum_image_cosine_distance']=max(data['image_cosine_distance']);row['maximum_text_cosine_distance']=max(data['query_cosine_distance']);row['raw_result']=p.name
 log=(r/('native-fp32-isolated-'+name+'.log')).read_text();external=re.search(r'(\d+)\s+maximum resident set size',log)
 if external:
  row['external_peak_rss_bytes']=int(external.group(1));row['external_extra_peak_rss_bytes']=int(external.group(1))-data['baseline_peak_rss_bytes'];row['external_rss_gate_passed']=row['external_extra_peak_rss_bytes']<=1_610_612_736
 rows.append(row)
summary=dict(version=1,ground_truth_sha256='c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025',acceptance=json.loads((r/'coreml-acceptance.json').read_text()),rows=rows,selected_lifecycle='text-first-per-model-pool',active_runtime_path=(r/'text-first-runtime-path.txt').read_text().strip(),limitations=['First tokenizer-first .all load exceeded memory gate; retained as a real failed lifecycle.','OS/CoreML caches already used and uncontrolled; no cache purge or claim of virgin installation.','Selected .all run used new UUID APFS-cloned, payload-hash-verified installation path; process/app caches empty.','Selected .all RSS margin only30,834,688bytes; no integrated PicEdit app RSS guarantee.','Index rate is tensor-to-image-embedding encoding, excludes photo decode/color conversion/preprocessing.','Cached-query timing reuses saved query vectors and includes linear10ksearch/top100sort, not an implemented product LRU.','Only one selected run per execution mode; no confidence intervals, macOS14/Intel/real-photo or thermal sweep.'])
(r/'isolated-fp32-gate-summary.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
for row in rows:
 print(row['run'],'gates',row['all_gates_passed'],'extraRSS',row['extra_peak_rss_bytes'],'p95ms',round(row['warm_full_query_p95_seconds']*1000,3))

#!/usr/bin/env python3
"""Run a pinned local MLX VLM on private fixtures, without sending the oracle.

No downloads are performed here. Results must use a new, separate directory.
One model worker processes images serially: concurrent 4B models would distort
memory measurements and compete for the same unified GPU memory. Independent
file verification and raster preparation use at most three background workers.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from hashlib import sha256
import importlib.metadata
from io import BytesIO
import json
import multiprocessing
import os
from pathlib import Path
import platform
import resource
import struct
import subprocess
import threading
import time
import traceback

from PIL import Image, ImageOps


def digest(path):
    with path.open('rb') as stream:
        return __import__('hashlib').file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def common_prompt(manifest, schema):
    """Allowlist the common task fields: per-case expectations never enter here."""
    return (manifest['model_prompt_de'] + '\n\n'
            'Antworte mit genau einem JSON-Objekt, ohne Markdown oder Zusatztext. '
            'tags enthalten nur tatsächlich sichtbare positive Aussagen. '
            'no_op und limitations_only haben eine leere edits-Liste. '
            'Das Antwortschema und die Begriffsdefinitionen gelten identisch für jedes Bild.\n'
            'Begriffsdefinitionen:\n' + json.dumps(manifest['response_contract'].get('tag_definitions', {}), ensure_ascii=False, sort_keys=True) +
            '\nAntwortschema:\n' + json.dumps(schema, ensure_ascii=False, sort_keys=True, separators=(',', ':')))


def grammar_schema(value):
    """Only syntax constraints supported by llguidance 1.9.1.

    The complete original schema remains unchanged and is validated afterward.
    Conditional edit rules and tag uniqueness are never silently counted as
    enforced by the decoder; neither function contains per-case information.
    """
    if isinstance(value, dict):
        return {key:grammar_schema(item) for key,item in value.items()
                if key not in ('uniqueItems','allOf')}
    if isinstance(value, list):
        return [grammar_schema(item) for item in value]
    return value


def prepare_case(item, fixtures, long_edge):
    source = item['source']
    name = source['file']
    path = fixtures / name
    if Path(name).name != name or path.resolve().parent != fixtures.resolve():
        raise ValueError('source must be inside the fixture directory')
    encoded = path.read_bytes()
    if sha256(encoded).hexdigest() != source['sha256']:
        raise ValueError('fixture source hash mismatch: ' + item['id'])
    with Image.open(BytesIO(encoded)) as image:
        image.load()
        if image.info.get('icc_profile') or image.getexif() or image.mode != 'RGB':
            raise ValueError('this runner requires the frozen untagged RGB/EXIF-free fixtures')
        if list(image.size) != [source['width'], source['height']]:
            raise ValueError('fixture dimensions changed')
        # Assign the documented sRGB interpretation; do not transform these
        # untagged bytes or copy filename/metadata into the model attachment.
        rgb = ImageOps.exif_transpose(image).convert('RGB')
        rgb.thumbnail((long_edge, long_edge), Image.Resampling.LANCZOS)
        pixels, dimensions = rgb.tobytes(), rgb.size
    raster_digest = sha256(struct.pack('>II', *dimensions) + b'RGB/sRGB\0' + pixels).hexdigest()
    return {'case_id': item['id'], 'source_sha256': source['sha256'],
            'input_raster_sha256': raster_digest, 'dimensions': dimensions, 'pixels': pixels}


def worker(connection, model_path, prompt, config, schema):
    # Downloads and telemetry are disabled before importing the inference stack.
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      HF_HUB_DISABLE_TELEMETRY='1', DO_NOT_TRACK='1',
                      TOKENIZERS_PARALLELISM='false')
    try:
        import mlx.core as mx
        from mlx_vlm import load, stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import prepare_inputs, should_add_special_tokens
        import psutil
        mx.set_cache_limit(config['allocator_cache_limit_bytes'])
        mx.set_memory_limit(config['allocator_memory_limit_bytes'])
        mx.random.seed(config['seed'])
        mx.synchronize()
        load_start = time.monotonic()
        model, processor = load(model_path, lazy=False, strict=True, trust_remote_code=False)
        mx.synchronize()
        load_seconds = time.monotonic()-load_start
        formatted = apply_chat_template(processor, model.config, prompt, num_images=1, enable_thinking=False)
        versions = {p: importlib.metadata.version(p) for p in
                    ['mlx-vlm', 'mlx', 'transformers', 'Pillow', 'psutil', 'huggingface-hub']}
        connection.send({'event': 'loaded', 'load_seconds': load_seconds,
                         'runtime_versions': versions, 'device': mx.device_info(),
                         'formatted_prompt_sha256': sha256(formatted.encode()).hexdigest(),
                         'formatted_prompt': formatted,
                         'active_memory_bytes': mx.get_active_memory(),
                         'rss_bytes': psutil.Process().memory_info().rss,
                         'ru_maxrss_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
        while True:
            payload = connection.recv()
            if payload is None:
                break
            # No case ID, filename, oracle, source metadata or ROI reaches worker.
            width, height, pixels = payload
            image = Image.frombytes('RGB', (width, height), pixels)
            gc = __import__('gc'); gc.collect(); mx.clear_cache(); mx.synchronize()
            mx.reset_peak_memory(); mx.random.seed(config['seed'])
            process = psutil.Process(); monitor_stop = threading.Event()
            rss_samples = [process.memory_info().rss]
            available = [psutil.virtual_memory().available]
            swap_before = psutil.swap_memory().used

            def monitor():
                while not monitor_stop.wait(.05):
                    rss_samples.append(process.memory_info().rss)
                    available.append(psutil.virtual_memory().available)

            monitor_thread = threading.Thread(target=monitor, daemon=True)
            monitor_thread.start()
            start = time.monotonic(); first_token_seconds = None
            text_parts = []; last = None
            try:
                prepared = prepare_inputs(processor, images=[image], prompts=formatted,
                                          image_token_index=getattr(model.config, 'image_token_index', None),
                                          add_special_tokens=should_add_special_tokens(model.config.model_type, processor))
                input_ids = prepared.pop('input_ids')
                pixel_values = prepared.pop('pixel_values')
                mask = prepared.pop('attention_mask', None)
                image_token_id = getattr(model.config, 'image_token_id', 248056)
                image_tokens = int(mx.sum(input_ids == image_token_id).item())
                if image_tokens <= 0 or pixel_values is None:
                    raise ValueError('image-bearing model input not verified')
                if input_ids.size > config['max_input_tokens']:
                    raise ValueError('input exceeds frozen token budget')
                grid = prepared.get('image_grid_thw')
                prepared_info = {'image_tokens': image_tokens, 'input_tokens': int(input_ids.size),
                                 'pixel_values_shape': list(pixel_values.shape),
                                 'image_grid_thw': grid.tolist() if grid is not None else None}
                processor.tokenizer.stopping_criteria.reset(model.config.eos_token_id)
                grammar_kwargs = {}
                if config['constrained_decoding']:
                    from mlx_vlm.structured import build_json_schema_logits_processor
                    # Stateful grammar matchers are fresh for every image; only
                    # the public response schema, never the case oracle, is used.
                    grammar_kwargs['logits_processors'] = [
                        build_json_schema_logits_processor(processor.tokenizer, grammar_schema(schema))]
                for part in stream_generate(model, processor, formatted,
                                            input_ids=input_ids, pixel_values=pixel_values, mask=mask, **prepared,
                                            max_tokens=config['max_new_tokens'],
                                            temperature=0.0, top_p=1.0, top_k=0,
                                            enable_thinking=False, prefill_step_size=512,
                                            verbose=False, **grammar_kwargs):
                    if first_token_seconds is None and part.text:
                        mx.synchronize()
                        first_token_seconds = time.monotonic()-start
                    text_parts.append(part.text); last = part
                mx.synchronize()
                if last is None:
                    raise RuntimeError('no generation result')
                raw = ''.join(text_parts)
                metrics = {'wall_seconds': time.monotonic()-start,
                           'time_to_first_text_seconds': first_token_seconds,
                           'mlx_peak_bytes': mx.get_peak_memory(),
                           'mlx_active_bytes': mx.get_active_memory(),
                           'mlx_cache_bytes': mx.get_cache_memory(),
                           'rss_sampled_peak_bytes': max(rss_samples+[process.memory_info().rss]),
                           'ru_maxrss_process_lifetime_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                           'system_min_available_bytes': min(available),
                           'system_swap_used_delta_bytes': psutil.swap_memory().used-swap_before,
                           'prompt_tokens': last.prompt_tokens, 'generation_tokens': last.generation_tokens,
                           'prompt_tokens_per_second': last.prompt_tps,
                           'generation_tokens_per_second': last.generation_tps,
                           'cached_tokens': last.cached_tokens}
                connection.send({'event': 'response', 'status': 'completed', 'response_text': raw,
                                 'generation': {'finish_reason': last.finish_reason or 'length'},
                                 'metrics': metrics, 'prepared_inputs': prepared_info})
                del prepared, input_ids, pixel_values, mask, last, image
            except Exception as error:
                connection.send({'event': 'response', 'status': 'inference_error',
                                 'error': type(error).__name__+': '+str(error), 'traceback': traceback.format_exc()})
                # A GPU error may leave allocator/device state unusable. Do not
                # silently retry the same image or continue in that state.
                break
            finally:
                monitor_stop.set(); monitor_thread.join(timeout=1)
    except BaseException as error:
        connection.send({'event': 'fatal', 'error': type(error).__name__+': '+str(error),
                         'traceback': traceback.format_exc()})
    finally:
        connection.close()


def receive(connection, process, seconds):
    deadline = time.monotonic()+seconds
    while time.monotonic() < deadline:
        if connection.poll(min(.25, max(0,deadline-time.monotonic()))):
            return connection.recv()
        if not process.is_alive():
            raise RuntimeError(f'model worker exited ({process.exitcode})')
    raise TimeoutError('model worker deadline exceeded')


def stop_worker(process, connection):
    if process.is_alive():
        try: connection.send(None)
        except (OSError, EOFError): pass
        process.join(timeout=3)
    if process.is_alive():
        process.terminate(); process.join(timeout=3)
    if process.is_alive():
        process.kill(); process.join(timeout=3)
    connection.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures',type=Path,required=True)
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--model-provenance',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--timeout',type=float,default=180)
    parser.add_argument('--long-edge',type=int,default=1024)
    parser.add_argument('--max-new-tokens',type=int,default=768)
    parser.add_argument('--constrained-decoding',action='store_true',
                        help='Enforce only the shared response schema, not scene-specific expectations')
    args=parser.parse_args(argv)
    if args.output.exists() or args.output.resolve()==args.fixtures.resolve():
        parser.error('output must be a new, separate directory')
    if not (args.model/'model.safetensors').is_file():
        parser.error('download the pinned local model first')
    if not 32<=args.long_edge<=1024 or not 1<=args.max_new_tokens<=2048 or not 1<=args.timeout<=600:
        parser.error('invalid bounded raster/token/deadline settings')
    manifest=json.loads((args.fixtures/'expectations.json').read_text())
    schema=json.loads((args.fixtures/'response.schema.json').read_text())
    provenance=json.loads(args.model_provenance.read_text())
    # Verify the pinned snapshot before any model code is loaded.
    for entry in provenance['files']:
        name=entry['file']
        if Path(name).name!=name or digest(args.model/name)!=entry['sha256']:
            raise ValueError('model snapshot mismatch')
    prompt=common_prompt(manifest,schema)
    with ThreadPoolExecutor(max_workers=3) as pool:
        prepared=list(pool.map(lambda c:prepare_case(c,args.fixtures,args.long_edge),manifest['cases']))
    args.output.mkdir(parents=True); (args.output/'responses').mkdir()
    (args.output/'common-prompt.txt').write_text(prompt)
    write_json(args.output/'response.schema.json',schema)
    if args.constrained_decoding:
        write_json(args.output/'decoder.schema.json',grammar_schema(schema))
    config={'seed':0,'max_new_tokens':args.max_new_tokens,'max_input_tokens':4096,
            'temperature':0.0,'top_p':1.0,'top_k':0,'enable_thinking':False,
            'constrained_decoding':args.constrained_decoding,'prefill_step_size':512,
            'decoder_constraints_deferred_to_validator':['uniqueItems','allOf conditional rules'] if args.constrained_decoding else [],
            'allocator_cache_limit_bytes':128*1024**2,
            'allocator_memory_limit_bytes':7*1024**3}
    run={'schema_version':1,'started_at_utc':datetime.now(timezone.utc).isoformat(),
         'suite_id':manifest['suite_id'],'model':provenance,'generation_config':config,
         'prompt_sha256':sha256(prompt.encode()).hexdigest(),
         'runner_source_sha256':digest(Path(__file__)),
         'expectations_sha256':digest(args.fixtures/'expectations.json'),
         'response_schema_sha256':digest(args.fixtures/'response.schema.json'),
         'hardware':{'machine':platform.machine(),'os':platform.platform(),
                     'macos':platform.mac_ver()[0]},
         'preprocessing':{'long_edge':args.long_edge,'filter':'PIL LANCZOS','color':'explicit sRGB interpretation of untagged fixtures','version':1},
         'inference_parallelism':1,'raster_preparation_parallelism':3,
         'cross_image_caches':False,'offline_inference':True,
         'cold_cache_claim':False,'render_status':'notRun',
         'limits':['16-GB device; model counters do not prove 8-GB whole-system fit.',
                   'RSS and MLX overlap; never add them together.',
                   'One serial pass, new conversation per image; first call is process-cold, not verified OS-cache-cold.']}
    (args.output/'requirements.freeze.txt').write_text(subprocess.check_output([os.sys.executable,'-m','pip','freeze'],text=True))
    write_json(args.output/'run.json',run)
    ctx=multiprocessing.get_context('spawn'); parent,child=ctx.Pipe()
    process=ctx.Process(target=worker,args=(child,str(args.model.resolve()),prompt,config,schema))
    process.start(); child.close()
    exit_code=0
    try:
        loaded=receive(parent,process,args.timeout)
        if loaded['event']!='loaded':
            run['startup_error']=loaded; raise RuntimeError(loaded.get('error','model startup failed'))
        formatted=loaded.pop('formatted_prompt')
        (args.output/'formatted-prompt.txt').write_text(formatted)
        run['loaded']=loaded; write_json(args.output/'run.json',run)
        print(json.dumps({'model_loaded':True,'load_seconds':loaded['load_seconds'],'active_memory_bytes':loaded['active_memory_bytes']}),flush=True)
        for index,item in enumerate(prepared):
            base={k:v for k,v in item.items() if k!='pixels'}
            base['ordinal']=index+1; base['worker_reused']=index>0
            parent.send((*item['dimensions'],item['pixels']))
            try:
                result=receive(parent,process,args.timeout)
            except TimeoutError:
                result={'status':'timeout','generation':{'finish_reason':'length'},'response_text':''}
            except (RuntimeError,EOFError,OSError) as error:
                result={'status':'inference_error','error':type(error).__name__+': '+str(error),'response_text':''}
            if result.get('event') == 'fatal' or result.get('status') not in ('completed','timeout','inference_error'):
                result={'status':'inference_error','error':result.get('error','invalid worker response'),'response_text':''}
            base.update(result)
            write_json(args.output/'responses'/(item['case_id']+'.json'),base)
            print(json.dumps({'case':item['case_id'],'status':base['status'],
                              'seconds':base.get('metrics',{}).get('wall_seconds'),
                              'tokens':base.get('metrics',{}).get('generation_tokens'),
                              'mlx_peak_bytes':base.get('metrics',{}).get('mlx_peak_bytes')}),flush=True)
            if base['status']!='completed':
                exit_code=1; break
    except BaseException as error:
        run['runner_error']=type(error).__name__+': '+str(error)
        exit_code=1
        print(run['runner_error'],flush=True)
    finally:
        stop_worker(process,parent)
        run['finished_at_utc']=datetime.now(timezone.utc).isoformat()
        run['exit_code']=exit_code
        write_json(args.output/'run.json',run)
    return exit_code


if __name__=='__main__':
    raise SystemExit(main())

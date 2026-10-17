"""CPU-only archival of completed native series; never launches a model.

Prepared, not run on a series. Original fixture/native data are read-only.
Frozen v1 compositor and frozen v2 estimator/compositor are imported byte-exact.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import shutil
from collections import Counter,defaultdict
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, PngImagePlugin

ROOT=Path(__file__).parent
EXPECTED={
 'evaluate-float-diagnostic-unbatched.py':'462ce4ad912e10bbcd5525135cd32e4d181f357687d60d35e95d15f300c0c254',
 'context-color-v2-proposal.json':'6363b33e560fe57232ac53568a71988cc85b704bfca4a8d3c057e3af112bc9b8',
 'context-color-v2-synthetic-test.py':'bad04e180decbe0b60c96bfb410a83bd033010023c3c16552277e04dafcd6d6e',
 'fixtures-manifest.json':'799d51e22631500e9caa2fbdd2c09403788d55d4248ddeacc9cc0db0c4a7a2d5',
}


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def inside(path,base=ROOT):
    path=path.resolve();path.relative_to(base.resolve());return path


def decode(a):return np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)


def diagnostics(source,native,mask,alpha,gain,spec):
    original=Image.fromarray(np.where(mask>0,255,0).astype(np.uint8))
    context=(np.asarray(original.filter(ImageFilter.MaxFilter(65)))!=0)&~(np.asarray(original.filter(ImageFilter.MaxFilter(9)))!=0)&(alpha==255)
    lo=spec['context']['allChannelsLinearMinimumExclusive'];hi=spec['context']['allChannelsLinearMaximumExclusive']
    context&=((source>lo)&(source<hi)&(native>lo)&(native<hi)).all(axis=2)
    y,x=np.indices(mask.shape);parity=(x//16+y//16)%2
    fit=context&(parity==0);validation=context&(parity==1)
    report={'usableContextPixels':int(context.sum()),'fitPixels':int(fit.sum()),'validationPixels':int(validation.sum())}
    if not fit.any():return report
    raw_gain=np.exp(np.median(np.log(source[fit])-np.log(native[fit]),axis=0))
    report['unclampedEstimatedGainRGB']=raw_gain.tolist()
    if gain is None:return report
    report['appliedGainRGB']=gain.tolist();report['gainClamped']=False
    report['gainChannelRatio']=float(gain.max()/gain.min())
    for name,selection in [('fit',fit),('validation',validation)]:
        if not selection.any():continue
        s=source[selection];g=native[selection];before=np.mean(np.abs(g-s));residual=g*gain-s;after=np.mean(np.abs(residual))
        report[name]={'pixelCount':int(selection.sum()),'meanAbsoluteLinearRGBErrorBefore':float(before),
          'meanAbsoluteLinearRGBErrorAfter':float(after),'errorReductionFraction':float(1-after/before) if before else None,
          'medianLinearRGBResidualAfter':np.median(residual,axis=0).tolist()}
    replacement=native[mask>0]*gain
    clipping=((replacement<0)|(replacement>1)).any(axis=1)
    report['replacementClippingPixelCount']=int(clipping.sum())
    report['replacementClippingFraction']=float(clipping.mean()) if clipping.size else 0
    return report


def sheet(source,mask,raw,v1,v2,rejection,path):
    panels=[('Source',source),('Replace mask',mask),('Native raw',raw),('v1: review required',v1),
            ('v2: REJECT '+rejection if rejection else 'v2: review required',v2)]
    output=Image.new('RGB',(1280,290),'white');draw=ImageDraw.Draw(output)
    for i,(label,im) in enumerate(panels):
        draw.text((i*256+4,5),label,fill='red' if im is None else 'black')
        if im is None:
            draw.text((i*256+8,75),'No v2 image published',fill='red');continue
        thumb=im.convert('RGBA');thumb.thumbnail((256,256))
        back=Image.new('RGBA',thumb.size,(238,238,238,255));back.alpha_composite(thumb)
        output.paste(back.convert('RGB'),(i*256,26))
    output.save(path)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--report',required=True);args=parser.parse_args()
    report_path=inside(Path(args.report),ROOT/'reports')
    report=json.loads(report_path.read_text());out=report_path.parent
    assert report.get('allOwnNativeProcessesEnded') is True,'postprocess only after actual helper exit'
    assert digest(ROOT/'evaluate-inpainting-series.swift')==report['harnessSourceSHA256']
    assert digest(Path(__file__))==report['postprocessSourceSHA256']
    for name,sha in EXPECTED.items():assert digest(ROOT/name)==sha,name+' changed'
    v1=load_module('frozen_v1',ROOT/'evaluate-float-diagnostic-unbatched.py')
    v2=load_module('frozen_v2',ROOT/'context-color-v2-synthetic-test.py')
    fixtures=v1.validate_fixtures();lookup={f['id']:f for f in fixtures['fixtures']}
    spec=json.loads((ROOT/'context-color-v2-proposal.json').read_text())
    event_statistics=defaultdict(list)
    event_path=out/'series-context/native-events.jsonl'
    if event_path.exists():
        assert event_path.stat().st_size<=64*1024*1024
        with event_path.open() as stream:
            for line in stream:
                assert len(line)<=65537
                event=json.loads(line)
                if event.get('event')=='float-diagnostic':event_statistics[event['id']].append(event['statistics'])
    results=[];errors=[]
    for operation in report['operations']:
        if operation.get('status')!='success':
            errors.append({'caseID':operation.get('caseID'),'status':'native-operation-failed','code':operation.get('code')});continue
        fixture=lookup[operation['fixtureID']]
        mask_info=next(m for m in fixture['masks'] if m['kind']==operation['maskKind'])
        native_path=inside(ROOT/operation['request']['output'],ROOT/'outputs')
        original_hash=digest(native_path)
        case_dir=out/'artifacts'/operation['caseID'];case_dir.mkdir(parents=True)
        archived_raw=case_dir/'raw.png';shutil.copy2(native_path,archived_raw)
        shutil.copy2(ROOT/fixture['source'],case_dir/'source.png')
        shutil.copy2(ROOT/mask_info['path'],case_dir/'replace-mask.png')
        v1_result=v1.save_result(fixture,mask_info,archived_raw,'v1')
        source_image=Image.open(ROOT/fixture['source']).convert('RGBA')
        mask_image=Image.open(ROOT/mask_info['path']).convert('L')
        raw_image=Image.open(archived_raw).convert('RGB')
        source=np.asarray(source_image,np.uint8);mask=np.asarray(mask_image,np.uint8);raw=np.asarray(raw_image,np.uint8)
        assert list(raw_image.size)==fixture['size']
        extrema_min=raw.min(axis=(0,1)).tolist();extrema_max=raw.max(axis=(0,1)).tolist()
        colors=int(np.unique(raw.reshape(-1,3),axis=0).shape[0])
        assert extrema_min==operation['nativeRGBMinimum'] and extrema_max==operation['nativeRGBMaximum']
        assert colors==operation['nativeDistinctRGBColors']
        a=decode(source[:,:,:3].astype(np.float64)/255);b=decode(raw.astype(np.float64)/255)
        v2_image=None;rejection=None;gain=None
        try:
            gain=v2.estimate(a,b,mask,source[:,:,3])
            pixels=v2.composite(source,b,mask,gain)
            assert np.array_equal(pixels[mask==0],source[mask==0])
            assert np.array_equal(pixels[:,:,3],source[:,:,3])
            v2_image=Image.fromarray(pixels,'RGBA')
            info=PngImagePlugin.PngInfo();info.add(b'sRGB',bytes([0]));v2_image.save(case_dir/'v2-final.png',pnginfo=info)
        except v2.Rejected as error:rejection=str(error)
        v2_diagnostics=diagnostics(a,b,mask,source[:,:,3],gain,spec)
        v2_status={'status':'REJECTED' if rejection else 'context-criteria-passed-visual-unverified','rejectCode':rejection,
          'diagnostics':v2_diagnostics,'proposalCanonicalSHA256':'fb746b30f85d6794255327e938228ff08f8b396972e4343538999b408bed9620',
          'backendGo':False,'thresholdsOrMaskChanged':False}
        if v2_image is not None:v2_status['finalSHA256']=digest(case_dir/'v2-final.png')
        (case_dir/'v2-diagnostics.json').write_text(json.dumps(v2_status,indent=2)+'\n')
        v1_image=Image.open(ROOT/v1_result['finalOutput']).convert('RGBA')
        sheet(source_image,mask_image,raw_image,v1_image,v2_image,rejection,case_dir/'comparison-v1-v2.png')
        review={'v1':'FAIL-degenerate-output' if colors<=1 else 'UNREVIEWED',
          'v2':'REJECTED' if rejection else 'UNREVIEWED','frozenExpectation':fixture['expectation'],
          'qualityGatesChanged':False,'nativeGenerationIsReal':True,'backendGo':False,
          'reviewInstruction':'Inspect full-size v1/v2 images, not only thumbnails. Record each frozen quality gate honestly; a context-color pass is not a visual pass.'}
        (case_dir/'visual-review-template.json').write_text(json.dumps(review,indent=2)+'\n')
        assert digest(native_path)==original_hash and digest(archived_raw)==original_hash
        stats=event_statistics[operation['caseID']];stage_counts=Counter(s['stage'] for s in stats)
        cfg=[s for s in stats if s['stage']=='actual-cfg-reference-check']
        float_check={
          'eventCount':len(stats),'stageCounts':dict(stage_counts),
          'allRecordedStagesFinite':bool(stats) and all(s.get('status')=='finite' for s in stats),
          'positiveRawOutputCount':stage_counts['unet-positive-raw-output-before-guidance'],
          'negativeRawOutputCount':stage_counts['unet-negative-raw-output-before-guidance'],
          'guidanceChecks':len(cfg),
          'guidanceViolations':sum(s['violations'] for s in cfg),
          'guidanceStorageAliases':sum(s['branchStorageAliased'] for s in cfg),
        }
        float_check['expected25StepBranchesVerified']=(float_check['allRecordedStagesFinite'] and
          float_check['positiveRawOutputCount']==25 and float_check['negativeRawOutputCount']==25 and
          len(cfg)==25 and float_check['guidanceViolations']==0 and float_check['guidanceStorageAliases']==0)
        (case_dir/'native-float-check.json').write_text(json.dumps(float_check,indent=2)+'\n')
        results.append({'caseID':operation['caseID'],'fixtureID':fixture['id'],'maskKind':mask_info['kind'],
          'role':operation['role'],'rawSHA256':original_hash,'v1':v1_result,'v2':v2_status,
          'nativeFloatCheck':float_check,'directory':str(case_dir),'outsideV1RGBAExactlySource':True,'allV1AlphaExactlySource':True})
    provenance=out/'provenance';provenance.mkdir(exist_ok=True)
    for name in ['fixtures-manifest.json','model-manifest.json','unbatched-configuration.json',
      'context-color-v2-proposal.json','evaluation-helper-float-diagnostic-unbatched.cpp',
      'float-diagnostic-unbatched-sdk.patch','picedit_float_diagnostic-unbatched.h',
      'evaluate-inpainting-series.swift','series-postprocess.py','THIRD-PARTY-NOTICES-EVALUATION.txt']:
        shutil.copy2(ROOT/name,provenance/name)
    artifact_hashes={str(p.relative_to(out)):digest(p) for p in sorted((out/'artifacts').rglob('*')) if p.is_file()}
    summary={'status':'archived-real-outputs-awaiting-manual-visual-review','nativeOperationFailures':errors,
      'successfulCases':results,'distinctFixtureIDsWithOutputs':sorted(set(x['fixtureID'] for x in results)),
      'allSixFixturesHaveRealOutputs':len(set(x['fixtureID'] for x in results))==6,
      'allSuccessfulOutputNativeFloatChecksPassed':bool(results) and all(x['nativeFloatCheck']['expected25StepBranchesVerified'] for x in results),
      'originalDataPreserved':True,'oldV1AndOfflineV2FailsUnchanged':True,'backendGo':False,
      'visualQualityStatus':'UNVERIFIED-except-explicit-rejects-or-degenerate-failures',
      'artifactSHA256':artifact_hashes,'newPostprocessVersion':'series-archive-v1-frozen-compositors',
      'provenanceSHA256':{str(p.relative_to(out)):digest(p) for p in sorted(provenance.rglob('*')) if p.is_file()},
      'postprocessFileSHA256':digest(Path(__file__))}
    (out/'postprocess-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({'summary':str(out/'postprocess-summary.json'),'outputs':len(results),
      'allSixFixturesHaveRealOutputs':summary['allSixFixturesHaveRealOutputs'],'backendGo':False},indent=2))


if __name__=='__main__':main()

"""Explicitly authorized offline v2 attempt on one stored output. No model/build.

Uses the frozen, already tested estimator/compositor without modifying either.
Original native/final/FAIL artifacts are read-only inputs.
"""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT=Path(__file__).parent
FROZEN_SPEC_SHA='fb746b30f85d6794255327e938228ff08f8b396972e4343538999b408bed9620'
FROZEN_TEST_SHA='bad04e180decbe0b60c96bfb410a83bd033010023c3c16552277e04dafcd6d6e'
ORIGINAL_REPORT=ROOT/'reports/20261016-123619-metal-float-diagnostic-unbatched-spike'


def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def eotf(a):return np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)


def main():
    spec=json.loads((ROOT/'context-color-v2-proposal.json').read_text())
    canonical=hashlib.sha256(json.dumps(spec,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    assert canonical==FROZEN_SPEC_SHA
    module_path=ROOT/'context-color-v2-synthetic-test.py'
    assert digest(module_path)==FROZEN_TEST_SHA
    module_spec=importlib.util.spec_from_file_location('frozen_context_color_v2',module_path)
    module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(module)
    native_report=json.loads((ORIGINAL_REPORT/'report.json').read_text())
    old_review=json.loads((ORIGINAL_REPORT/'visual-review.json').read_text())
    assert old_review['status']=='FAIL'
    op=native_report['operations'][0]
    source_path=ROOT/'fixtures/01-structured-removal-source.png'
    mask_path=ROOT/'fixtures/01-structured-removal-mask-hard.png'
    raw_path=ROOT/op['rawOutput'];old_final_path=ROOT/op['finalOutput']
    originals=[source_path,mask_path,raw_path,old_final_path,ORIGINAL_REPORT/'report.json',ORIGINAL_REPORT/'visual-review.json']
    before={str(p):digest(p) for p in originals}
    assert digest(raw_path)==op['rawSHA256'] and digest(old_final_path)==op['finalSHA256']
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    out=ROOT/'reports'/f'{stamp}-offline-context-color-v2'
    out.mkdir()
    source_image=Image.open(source_path).convert('RGBA');source_rgba=np.array(source_image,np.uint8)
    raw_image=Image.open(raw_path).convert('RGB');raw=np.array(raw_image,np.uint8)
    mask_image=Image.open(mask_path).convert('L');mask=np.array(mask_image,np.uint8)
    source_linear=eotf(source_rgba[:,:,:3].astype(np.float64)/255)
    native_linear=eotf(raw.astype(np.float64)/255)
    report={'status':'running-offline-v2-only','proposalCanonicalSHA256':canonical,
      'proposalFileSHA256':digest(ROOT/'context-color-v2-proposal.json'),
      'frozenEstimatorAndSyntheticTestSHA256':digest(module_path),
      'nativeConfigurationCanonicalSHA256':native_report['configurationSHA256'],
      'originalInputsSHA256':before,'buildOrModelInvoked':False,'thresholdsChanged':False,
      'originalQualityDecision':'FAIL-unchanged','qualityDecisionV2':'awaiting-explicit-visual-review',
      'backendGo':False}
    try:
        gain=module.estimate(source_linear,native_linear,mask,source_rgba[:,:,3])
        # Reconstruct exactly the frozen contexts for a transparent report only.
        original=Image.fromarray(np.where(mask>0,255,0).astype(np.uint8))
        outer=np.asarray(original.filter(ImageFilter.MaxFilter(65)))!=0
        inner=np.asarray(original.filter(ImageFilter.MaxFilter(9)))!=0
        context=outer&~inner&(source_rgba[:,:,3]==255)
        lo=spec['context']['allChannelsLinearMinimumExclusive'];hi=spec['context']['allChannelsLinearMaximumExclusive']
        context&=((source_linear>lo)&(source_linear<hi)&(native_linear>lo)&(native_linear<hi)).all(axis=2)
        y,x=np.indices(mask.shape);parity=(x//16+y//16)%2
        fit=context&(parity==0);validation=context&(parity==1)
        raw_gain=np.exp(np.median(np.log(source_linear[fit])-np.log(native_linear[fit]),axis=0))
        expected_gain=np.ones(3) if np.max(np.abs(raw_gain-1))<=spec['estimator']['identityGainTolerance'] else raw_gain
        assert np.array_equal(gain,expected_gain)
        diagnostics={}
        for name,selection in [('fit',fit),('validation',validation),('all-context',context)]:
            s=source_linear[selection];g=native_linear[selection]
            before_error=np.abs(g-s).mean();residual=g*gain-s;after_error=np.abs(residual).mean()
            diagnostics[name]={'pixelCount':int(selection.sum()),
              'meanAbsoluteLinearRGBErrorBefore':float(before_error),
              'meanAbsoluteLinearRGBErrorAfter':float(after_error),
              'errorReductionFraction':float(1-after_error/before_error) if before_error else None,
              'medianLinearRGBResidualBefore':np.median(g-s,axis=0).tolist(),
              'medianLinearRGBResidualAfter':np.median(residual,axis=0).tolist(),
              'meanLinearLuminanceSource':float(np.mean(s@np.array([.2126,.7152,.0722]))),
              'meanLinearLuminanceNativeBefore':float(np.mean(g@np.array([.2126,.7152,.0722]))),
              'meanLinearLuminanceNativeAfter':float(np.mean((g*gain)@np.array([.2126,.7152,.0722])))}
        replacement=native_linear[mask>0]*gain
        clipping=((replacement<0)|(replacement>1)).any(axis=1)
        report.update({'gainRGB':gain.tolist(),'unroundedEstimatorGainRGB':raw_gain.tolist(),
          'gainClamped':False,'gainChannelRatio':float(gain.max()/gain.min()),
          'contextDiagnostics':diagnostics,
          'replacementPixelCount':int(replacement.shape[0]),
          'replacementClippingPixelCount':int(clipping.sum()),
          'replacementClippingFraction':float(clipping.mean()) if clipping.size else 0,
          'replacementLinearRGBMinimum':replacement.min(axis=0).tolist(),
          'replacementLinearRGBMaximum':replacement.max(axis=0).tolist()})
        result=module.composite(source_rgba,native_linear,mask,gain)
        assert np.array_equal(result[mask==0],source_rgba[mask==0])
        assert np.array_equal(result[:,:,3],source_rgba[:,:,3])
        final_path=out/'candidate-v2-final.png'
        Image.fromarray(result,'RGBA').save(final_path)
        # Add same explicit sRGB intent as the existing evaluation final; no pixel conversion.
        from PIL.PngImagePlugin import PngInfo
        info=PngInfo();info.add(b'sRGB',bytes([0]))
        Image.fromarray(result,'RGBA').save(final_path,pnginfo=info)
        panels=[('Source',source_image),('Replace mask',mask_image),('Native raw',raw_image),
          ('v1 final: FAIL',Image.open(old_final_path).convert('RGBA')),
          ('v2 candidate',Image.fromarray(result,'RGBA'))]
        comparison=Image.new('RGB',(len(panels)*256,282),'white');draw=ImageDraw.Draw(comparison)
        for i,(label,im) in enumerate(panels):
            draw.text((i*256+5,5),label,fill='black')
            thumb=im.convert('RGBA').resize((256,256),Image.Resampling.LANCZOS)
            background=Image.new('RGBA',thumb.size,(238,238,238,255));background.alpha_composite(thumb)
            comparison.paste(background.convert('RGB'),(i*256,26))
        comparison_path=out/'comparison-source-mask-native-v1-v2.png';comparison.save(comparison_path)
        report.update({'status':'offline-v2-context-criteria-passed-awaiting-visual-review',
          'candidateFinal':str(final_path),'candidateFinalSHA256':digest(final_path),
          'comparison':str(comparison_path),'comparisonSHA256':digest(comparison_path),
          'outsideRGBAExactlySource':True,'allAlphaExactlySource':True})
    except module.Rejected as error:
        report.update({'status':'offline-v2-rejected','rejectCode':str(error),
          'qualityDecisionV2':'REJECTED-no-output-published'})
    finally:
        assert all(digest(p)==before[str(p)] for p in originals)
        report['originalInputsPreserved']=True
        report['driverSHA256']=digest(Path(__file__))
        (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(str(out/'report.json'));print(json.dumps(report,indent=2))


if __name__=='__main__':main()

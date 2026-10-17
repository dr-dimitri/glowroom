"""Small CPU-only synthetic proof for a proposed v2, not a product adapter.

No model/source PNG path is read or written by this script. In particular, no
correction is applied to the stored FAIL image. Parameters are frozen in JSON.
"""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).parent
SPEC_PATH = ROOT / "context-color-v2-proposal.json"
SPEC = json.loads(SPEC_PATH.read_text())


class Rejected(ValueError):
    pass


def estimate(source, native, mask, alpha):
    if source.shape != native.shape or source.shape[:2] != mask.shape or alpha.shape != mask.shape:
        raise Rejected("geometry")
    if not (np.isfinite(source).all() and np.isfinite(native).all()):
        raise Rejected("nonfinite")
    original = Image.fromarray(np.where(mask > 0,255,0).astype(np.uint8))
    outer = np.asarray(original.filter(ImageFilter.MaxFilter(65))) != 0
    inner = np.asarray(original.filter(ImageFilter.MaxFilter(9))) != 0
    context = outer & ~inner & (alpha == 255)
    lo, hi = SPEC['context']['allChannelsLinearMinimumExclusive'], SPEC['context']['allChannelsLinearMaximumExclusive']
    context &= ((source > lo) & (source < hi) & (native > lo) & (native < hi)).all(axis=2)
    if context.sum() < SPEC['context']['minimumUsablePixels']:
        raise Rejected("context")
    y,x=np.indices(mask.shape)
    parity=(x//16+y//16)%2
    fit=context & (parity==0)
    validation=context & (parity==1)
    if fit.sum()<SPEC['context']['minimumFitPixels'] or validation.sum()<SPEC['context']['minimumValidationPixels']:
        raise Rejected("partition")
    gain=np.exp(np.median(np.log(source[fit])-np.log(native[fit]),axis=0))
    e=SPEC['estimator']; v=SPEC['validation']
    if gain.min()<e['minimumGain'] or gain.max()>e['maximumGain'] or gain.max()/gain.min()>e['maximumChannelGainRatio']:
        raise Rejected("gain")
    neutral=bool(np.max(np.abs(gain-1))<=e['identityGainTolerance'])
    if neutral: gain=np.ones(3)
    before=np.mean(np.abs(native[validation]-source[validation]))
    residual=native[validation]*gain-source[validation]
    after=np.mean(np.abs(residual))
    if after>v['maximumMeanAbsoluteLinearRGBResidual'] or np.max(np.abs(np.median(residual,axis=0)))>v['maximumAbsoluteMedianPerChannelLinearResidual']:
        raise Rejected("validation-residual")
    if not neutral and after>before*(1-v['minimumMeanAbsoluteLinearRGBErrorReductionFraction']):
        raise Rejected("validation-reduction")
    replacement=native[mask>0]*gain
    clipping=((replacement<0)|(replacement>1)).any(axis=1)
    if clipping.size and clipping.mean()>v['maximumCorrectedReplacementClippingFraction']:
        raise Rejected("replacement-clipping")
    return gain


def composite(source_rgba, native_linear, mask, gain):
    # Synthetic-only exercise of the proposed output invariants.
    coded=source_rgba[:,:,:3].astype(np.float64)/255
    source=np.where(coded<=.04045,coded/12.92,((coded+.055)/1.055)**2.4)
    w=mask[:,:,None].astype(np.float64)/255
    mixed=source*(1-w)+np.clip(native_linear*gain,0,1)*w
    encoded=np.where(mixed<=.0031308,mixed*12.92,1.055*mixed**(1/2.4)-.055)
    out=source_rgba.copy()
    out[:,:,:3]=np.rint(np.clip(encoded,0,1)*255).astype(np.uint8)
    out[mask==0]=source_rgba[mask==0]
    return out


def reject(call):
    try: call()
    except Rejected as error: return str(error)
    raise AssertionError("expected rejection")


def main():
    y,x=np.indices((256,256))
    mask=np.where((x-128)**2+(y-128)**2<=42**2,255,0).astype(np.uint8)
    alpha=np.full(mask.shape,255,np.uint8)
    source=np.stack([.10+.35*x/255,.12+.38*y/255,.08+.33*(x+y)/510],axis=2)
    tests={}
    gain=estimate(source,source.copy(),mask,alpha)
    assert np.array_equal(gain,np.ones(3)); tests['identity']='PASS'
    expected=np.array([1.20,1.10,1.00])
    native=source/expected
    gain=estimate(source,native,mask,alpha)
    assert np.max(np.abs(gain-expected))<1e-12
    assert np.max(np.abs(native*gain-source))<1e-12
    tests['known-exposure-and-cast-recovered']='PASS'
    contaminated=native.copy()
    # Sparse unrelated context changes must not steer a robust median estimator.
    contaminated[(x%11==0)&(y%7==0)]=.8
    assert np.max(np.abs(estimate(source,contaminated,mask,alpha)-expected))<1e-12
    tests['sparse-context-outliers']='PASS'
    changed=native.copy(); changed[mask>0]=.20
    assert np.array_equal(estimate(source,changed,mask,alpha),gain)
    tests['replacement-content-not-used-to-fit']='PASS'
    tests['insufficient-context']=reject(lambda:estimate(source,native,np.full_like(mask,255),alpha))
    bad=native.copy();bad[0,0,0]=np.nan
    tests['nonfinite-rejection']=reject(lambda:estimate(source,bad,mask,alpha))
    tests['excess-gain-rejection']=reject(lambda:estimate(source,source/2,mask,alpha))
    clipped=native.copy();clipped[mask>0]=1
    tests['replacement-clipping-rejection']=reject(lambda:estimate(source,clipped,mask,alpha))
    variable=native.copy();variable[(x//16+y//16)%2==1]*=.7
    tests['heldout-mismatch-rejection']=reject(lambda:estimate(source,variable,mask,alpha))
    coded=np.where(source<=.0031308,source*12.92,1.055*source**(1/2.4)-.055)
    rgba=np.concatenate([np.rint(coded*255).astype(np.uint8),alpha[:,:,None]],axis=2)
    rgba[mask>0,3]=117
    result=composite(rgba,native,mask,gain)
    assert np.array_equal(result[mask==0],rgba[mask==0])
    assert np.array_equal(result[:,:,3],rgba[:,:,3])
    assert np.max(np.abs(result[mask>0,:3].astype(int)-rgba[mask>0,:3].astype(int)))<=1
    tests['exterior-RGBA-and-all-alpha-exact']='PASS'
    tests['recovered-synthetic-interior-within-one-code-value']='PASS'
    report={
        'status':'PASS-synthetic-only-no-model-output-corrected',
        'proposalFileSHA256':hashlib.sha256(SPEC_PATH.read_bytes()).hexdigest(),
        'proposalCanonicalSHA256':hashlib.sha256(json.dumps(SPEC,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
        'testFileSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'tests':tests,'fixtureGatesChanged':False,'storedQualityDecision':'FAIL-unchanged',
        'releaseApproved':False
    }
    (ROOT/'context-color-v2-synthetic-test-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

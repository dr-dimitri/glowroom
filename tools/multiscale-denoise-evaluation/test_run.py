import copy
import importlib.util
import json
from pathlib import Path
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("multiscale_protocol",HERE/"run.py")
protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
M=json.loads((HERE/"manifest.json").read_text())


def metric(detail=.01):
    result={k:0.0 for k in M["criticalGates"]}
    result.update({"detail_rgb_rmse":detail,"edge_gradient_rmse":detail,"noise_sample_count":100,"noise_visible_weight":100,"detail_sample_count":100,"detail_visible_weight":100,"edge_sample_count":100,"edge_visible_weight":100,"alpha_error":0,"hidden_rgb_error":0})
    for c in ("luma","chroma"):
        result[f"input_noise_{c}_rmse"]=.02;result[f"noise_{c}_rmse"]=.018
    return result


def evidence():
    tuning=[];rows=[]
    for scene,control,value in sorted(protocol.expected(M)):
        targets={c:.1 for c in protocol.components(control)}
        parameters={"luminance":0 if control=="chroma" else 20,"chroma":0 if control=="luminance" else 20}
        tuning.append({"scene":scene,"control":control,"value":value,**parameters,"targets":targets,"measured":targets,"matched":True,"inputSHA256":"a"*64,"truthSHA256":"c"*64})
        rows.append({"scene":scene,"control":control,"value":value,**parameters,"targets":targets,"measured":targets,"matched":True,"tuningMatched":True,"inputSHA256":"b"*64,"truthSHA256":"c"*64,"outputSHA256":"d"*64,"baseline":metric(),"candidate":metric(.008)})
    zero=[{"scene":s,"control":c,"inputSHA256":"a"*64,"outputSHA256":"a"*64,"identity":True} for s in M["scenes"] for c in M["controls"]]
    return {"records":tuning},{"records":rows,"zero":zero}


class ProtocolTests(unittest.TestCase):
    def test_matching_requires_positive_reduction_and_issue_tolerances(self):
        self.assertFalse(protocol.matches(0,0,M));self.assertFalse(protocol.matches(.00019,.00019,M))
        self.assertTrue(protocol.matches(.1,.104,M));self.assertFalse(protocol.matches(.1,.106,M))
        self.assertFalse(protocol.matches(float("nan"),.1,M))

    def test_complete_synthetic_quality_cannot_promote_without_required_evidence(self):
        tuning,q=evidence();protocol.validate_calibration(tuning,M,q)
        for d in protocol.quality_decisions(q,M).values():
            self.assertEqual(d["qualityDecision"],"pass");self.assertEqual(d["promotionDecision"],"no-go")
            self.assertIn("real RAW-developed photographs",d["promotionMissingEvidence"])

    def test_quality_means_and_per_case_regression_are_separate(self):
        _,q=evidence()
        row=next(r for r in q["records"] if r["scene"]=="texture" and r["control"]=="chroma" and r["value"]==20)
        row["candidate"]["detail_rgb_rmse"]=.012
        d=protocol.quality_decisions(q,M)
        self.assertEqual(d["chroma"]["qualityDecision"],"no-go")
        self.assertTrue(any("per-case" in x for x in d["chroma"]["failures"]))
        self.assertEqual(d["luminance"]["qualityDecision"],"pass")

    def test_unmatched_acceptance_is_blocked_and_cannot_donate_metrics(self):
        _,q=evidence();r=next(r for r in q["records"] if r["control"]=="luminance")
        r["measured"]={"luminance":.05};r["candidate"]["noise_luma_rmse"] = .019;r["matched"]=False
        d=protocol.quality_decisions(q,M)["luminance"]
        self.assertEqual(d["qualityDecision"],"blocked")

    def test_forged_matching_and_residuals_are_rejected(self):
        for key in ("matched","residual"):
            _,q=evidence()
            if key=="matched":q["records"][0]["matched"]=False
            else:
                prefix="chroma" if q["records"][0]["control"]=="chroma" else "luma"
                q["records"][0]["candidate"][f"noise_{prefix}_rmse"] = .001
            with self.assertRaises(ValueError):protocol.quality_decisions(q,M)

    def test_calibration_rejects_acceptance_refit_seed_reuse_and_truth_change(self):
        for key,value in (("luminance",99),("inputSHA256","a"*64),("truthSHA256","d"*64)):
            tuning,q=evidence();q["records"][0][key]=value
            with self.assertRaises(ValueError):protocol.validate_calibration(tuning,M,q)

    def test_incomplete_duplicate_missing_or_nonfinite_metrics_are_rejected(self):
        for defect in ("incomplete","duplicate","missing","nonfinite"):
            _,q=evidence()
            if defect=="incomplete":q["records"].pop()
            if defect=="duplicate":q["records"].append(copy.deepcopy(q["records"][0]))
            if defect=="missing":del q["records"][0]["candidate"]["target_outside_fraction"]
            if defect=="nonfinite":q["records"][0]["candidate"]["detail_rgb_rmse"]=float("nan")
            with self.assertRaises(ValueError):protocol.quality_decisions(q,M)

    def test_alpha_contract_cannot_be_hidden_by_matching_failure(self):
        _,q=evidence();r=q["records"][0];r["candidate"]["alpha_error"]=.01
        self.assertEqual(protocol.quality_decisions(q,M)[r["control"]]["qualityDecision"],"no-go")

    def test_timing_at_different_effect_is_never_a_speed_claim(self):
        a={"inputSHA256":"a"*64,"samples":[{"phase":p,"milliseconds":10,"rss":100,"reduction":.1} for p in ["cold","warmup"]+["warm"]*5]}
        b=copy.deepcopy(a)
        self.assertEqual(protocol.performance_pair(a,b,M)["decision"],"pass")
        b["samples"][2]["reduction"]=.05
        self.assertEqual(protocol.performance_pair(a,b,M)["decision"],"blocked")

    def test_missing_masks_cannot_be_interpreted_as_primary_failure(self):
        _,q=evidence()
        row=next(r for r in q["records"] if r["control"]=="luminance" and r["scene"]=="texture" and r["value"]==20)
        row["candidate"]["edge_sample_count"]=0
        row["candidate"]["detail_rgb_rmse"]=1
        decision=protocol.quality_decisions(q,M)["luminance"]
        self.assertEqual(decision["qualityDecision"],"blocked")
        self.assertFalse(decision["means"])

    def test_other_unmatched_case_cannot_erase_independent_matched_veto(self):
        _,q=evidence()
        row=next(r for r in q["records"] if r["control"]=="joint" and r["scene"]=="texture" and r["value"]==60)
        row["candidate"]["edge_gradient_rmse"] = .012
        other=next(r for r in q["records"] if r["control"]=="joint" and r["scene"]=="dark-edges" and r["value"]==20)
        other["tuningMatched"]=False;other["matched"]=False
        decision=protocol.quality_decisions(q,M)["joint"]
        self.assertEqual(decision["qualityDecision"],"no-go")
        self.assertIn("per-case edge_gradient_rmse: texture/60",decision["failures"])
        self.assertFalse(decision["means"])

    def test_candidate_constants_and_gates_cannot_drift_from_frozen_design(self):
        protocol.validate_manifest(M)
        for group,key,value in (("candidate","thresholds",[.05,.03,.02]),("matching","relativeTolerance",.1),("qualityGates","minimumMeanImprovement",0),("criticalGates","target_outside_fraction",1)):
            changed=copy.deepcopy(M);changed[group][key]=value
            with self.assertRaises(ValueError):protocol.validate_manifest(changed)

    def test_nonfinite_and_negative_performance_cannot_claim_speed(self):
        a={"inputSHA256":"a"*64,"samples":[{"phase":p,"milliseconds":10,"rss":100,"reduction":.1} for p in ["cold","warmup"]+["warm"]*5]}
        for value in (-1,float("nan"),0):
            b=copy.deepcopy(a);b["samples"][0]["milliseconds"]=value
            with self.assertRaises(ValueError):protocol.performance_pair(a,b,M)

    def test_scale_requires_complete_noninteger_preview_matrix(self):
        with self.assertRaises(ValueError):protocol.scale_decision({"records":[]},M)


if __name__=="__main__":unittest.main()

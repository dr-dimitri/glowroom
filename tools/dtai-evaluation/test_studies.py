import json
import hashlib
import io
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from contracts import PromptFrame, segnext_gate
from run import freeze_files, read_json, receipt, verify_files, write_json
from adapters import (FileSnapshot, OnnxCPU, SegNext, binary_iou, camera_to_rec2020, load_npy, match_gain, mirror_indices, pack_bayer,
                      prepare_segnext, preserve_alpha, project_segnext, tensor, tiled, transfer)
try:
    import numpy as np
except ImportError:
    np = None

SOURCE = "a"*64


class GeometryTests(unittest.TestCase):
    def test_all_orientations_rotations_and_preview_roundtrip(self):
        for orientation in range(1,9):
            for turns in range(4):
                frame = PromptFrame(SOURCE,601,401,orientation,turns=turns)
                for point in ((.5,.5),(600.5,.5),(.5,400.5),(600.5,400.5),(200.25,100.75)):
                    prompt = frame.to_prompt(point,source_sha256=SOURCE,frame_id=frame.identity)
                    restored = frame.from_prompt(prompt)
                    self.assertAlmostEqual(restored[0],point[0])
                    self.assertAlmostEqual(restored[1],point[1])
                    preview = (prompt[0]*300/1024,prompt[1]*200/1024)
                    restored = frame.preview_to_original(preview,(300,200))
                    self.assertAlmostEqual(restored[0],point[0])
                    self.assertAlmostEqual(restored[1],point[1])

    def test_crop_roundtrip_and_outside_rejected(self):
        frame = PromptFrame(SOURCE,600,400,6,crop=(20,30,200,300),turns=3)
        point = frame.from_prompt((400,500))
        self.assertEqual(frame.to_prompt(point,source_sha256=SOURCE,frame_id=frame.identity),(400,500))
        with self.assertRaises(ValueError):
            frame.to_prompt((0,0),source_sha256=SOURCE,frame_id=frame.identity)

    def test_source_and_preparation_ownership(self):
        frame = PromptFrame(SOURCE,600,400)
        with self.assertRaises(ValueError):
            frame.to_prompt((3,4),source_sha256="b"*64,frame_id=frame.identity)
        with self.assertRaises(ValueError):
            frame.to_prompt((3,4),source_sha256=SOURCE,frame_id="old")
        self.assertNotEqual(frame.identity,PromptFrame(SOURCE,600,400,turns=1).identity)

    def test_invalid_geometry_and_coordinates(self):
        for args in ((SOURCE,0,3),(SOURCE,3,4,9),(SOURCE,3,4,1,(0,0,4,2)),("bad",3,4)):
            with self.assertRaises(ValueError):
                PromptFrame(*args)
        frame = PromptFrame(SOURCE,3,4)
        for point in ((-1,0),(3,1),(float("nan"),0),(0,float("inf"))):
            with self.assertRaises(ValueError):
                frame.to_prompt(point,source_sha256=SOURCE,frame_id=frame.identity)


class GateTests(unittest.TestCase):
    def cases(self):
        return [{"id":str(i),"start_iou":.7,"click_ious":[.8,.86,.9],"native_reference_iou":.995} for i in range(12)]

    def test_quality_pass_does_not_assert_product_go(self):
        result = segnext_gate(self.cases())
        self.assertEqual(result["quality"],"quality-pass-unqualified")
        self.assertEqual(result["bounded_mean_noc85"],2)
        self.assertEqual(result["unreached"],0)

    def test_no_target_is_eleven_not_ten(self):
        cases = self.cases()
        cases[0]["click_ious"] = [.84]*10
        result = segnext_gate(cases)
        self.assertEqual(result["cases"][0]["noc85"],11)
        self.assertEqual(result["unreached"],1)

    def test_start_above_target_needs_zero_corrections(self):
        cases = self.cases()
        cases[0]["start_iou"] = .86
        self.assertEqual(segnext_gate(cases)["cases"][0]["noc85"],0)

    def test_all_three_quality_gates_are_enforced(self):
        cases = self.cases()
        for c in cases:
            c["click_ious"] = [.72]*10
            c["native_reference_iou"] = .98
        self.assertEqual(len(segnext_gate(cases)["failures"]),3)

    def test_missing_duplicates_nonfinite_and_click_limit_rejected(self):
        for mutation in (lambda c:c.pop(),lambda c:c[1].update(id="0"),
                         lambda c:c[0].update(start_iou=float("nan")),
                         lambda c:c[0].update(click_ious=[.9]*11),
                         lambda c:c[0].update(click_ious=[])):
            cases = self.cases()
            mutation(cases)
            with self.assertRaises(ValueError):
                segnext_gate(cases)

    def test_reports_do_not_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"result.json"
            write_json(path,{"decision":"no-go"})
            with self.assertRaises(FileExistsError):
                write_json(path,{"decision":"go"})
            self.assertEqual(json.loads(path.read_text())["decision"],"no-go")

    def test_receipt_cannot_omit_weight_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"receipt.json"
            path.write_text('{"source_revision":"wrong"}')
            with self.assertRaises(ValueError):
                receipt(path,"nafnet")

    def test_mutated_research_inputs_fail_before_report(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"input.npy"
            path.write_bytes(b"frozen tensor")
            frozen = freeze_files((path,))
            verify_files(frozen)
            path.write_bytes(b"changed tensor")
            with self.assertRaises(ValueError):
                verify_files(frozen)

    def test_snapshot_budget_is_shared_across_files(self):
        with tempfile.TemporaryDirectory() as folder:
            a,b = Path(folder)/"a",Path(folder)/"b"
            a.write_bytes(b"abc")
            b.write_bytes(b"de")
            with self.assertRaises(ValueError):
                freeze_files((a,b),max_bytes=4)
            self.assertEqual(len(freeze_files((a,a),max_bytes=3)),1)

    def test_json_decode_uses_frozen_bytes_during_a_b_a_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ("receipt.json","frame.json","clicks.json"):
                path = Path(folder)/name
                original = b'{"identity":"A"}'
                path.write_bytes(original)
                frozen = freeze_files((path,))
                path.write_bytes(b'{"identity":"B"}')
                decoded = read_json(frozen[str(path)])
                path.write_bytes(original)
                verify_files(frozen)  # A post-hoc path hash alone misses A->B->A.
                self.assertEqual(decoded,{"identity":"A"})
                self.assertEqual(frozen[str(path)].digest,hashlib.sha256(original).hexdigest())

    def test_duplicate_json_keys_refused_at_every_nesting_level(self):
        for data in (b'{"model_sha256":"A","model_sha256":"B"}',
                     b'{"frame":{"width":10,"width":20}}',
                     b'[{"label":1,"label":0}]'):
            with self.assertRaisesRegex(ValueError,"duplicate JSON key"):
                read_json(FileSnapshot(data))


class OnnxSnapshotTests(unittest.TestCase):
    class Message:
        def __init__(self,name="onnx.ModelProto",children=(),*,external_location=0,external_entries=()):
            self.DESCRIPTOR = SimpleNamespace(full_name=name)
            self.children = children
            self.data_location,self.external_data = external_location,external_entries
        def ListFields(self):
            # Exercise repeated and singular protobuf submessages.
            return [(SimpleNamespace(message_type=object(),is_repeated=repeated),value) for repeated,value in self.children]

    def modules(self,model,on_session):
        class Session:
            def __init__(self,model_bytes,*args,**kwargs):
                on_session(model_bytes)
            def get_inputs(self): return []
            def get_outputs(self): return []
            def get_providers(self): return ["CPUExecutionProvider"]
        onnx = SimpleNamespace(load_model_from_string=lambda data:model,TensorProto=SimpleNamespace(EXTERNAL=1))
        ort = SimpleNamespace(SessionOptions=SimpleNamespace,ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL=0),InferenceSession=Session)
        return {"onnx":onnx,"onnxruntime":ort}

    def test_ort_receives_exact_hashed_bytes_during_a_b_a_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"model.onnx"
            original = b"model A inline protobuf stub"
            path.write_bytes(original)
            frozen = freeze_files((path,))
            snapshot = frozen[str(path)]
            received = []
            def native_load(model_bytes):
                # A pathname session would load B here and later rehash A.
                path.write_bytes(b"model B")
                received.append(model_bytes)
                path.write_bytes(original)
            with patch.dict("sys.modules",self.modules(self.Message(),native_load)):
                session = OnnxCPU(snapshot,snapshot.digest,{}, {})
                with self.assertRaises(ValueError):
                    OnnxCPU(path,snapshot.digest,{}, {})
            verify_files(frozen)
            self.assertEqual(received,[original])
            self.assertIs(type(received[0]),bytes)
            self.assertEqual(session.sha256,hashlib.sha256(original).hexdigest())

    def test_external_data_refused_in_nested_tensor_before_native_load(self):
        for location,entries in ((1,()),(0,("location=weights.bin",))):
            tensor_message = self.Message("onnx.TensorProto",external_location=location,external_entries=entries)
            nested = self.Message("onnx.GraphProto",((True,[tensor_message]),))
            root = self.Message(children=((False,nested),))
            snapshot = FileSnapshot(b"external model protobuf stub")
            with patch.dict("sys.modules",self.modules(root,lambda _:self.fail("external model must never reach ORT"))):
                with self.assertRaisesRegex(ValueError,"ExternalData"):
                    OnnxCPU(snapshot,snapshot.digest,{}, {})

    def test_snapshot_rejects_mutable_storage(self):
        with self.assertRaises(ValueError):
            FileSnapshot(bytearray(b"mutable"))


@unittest.skipIf(np is None,"NumPy required: use the isolated pinned environment or bundled Python")
class TensorTests(unittest.TestCase):
    def test_npy_header_cannot_allocate_beyond_budget_or_missing_payload(self):
        buffer = io.BytesIO()
        np.save(buffer,np.zeros((1,3,2,2),np.float32),allow_pickle=False)
        with self.assertRaises(ValueError):
            load_npy(FileSnapshot(buffer.getvalue()),max_array_bytes=4)
        with self.assertRaises(ValueError):
            load_npy(FileSnapshot(buffer.getvalue()[:-4]))

    def test_npy_decode_uses_frozen_bytes_during_a_b_a_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"input.npy"
            original = io.BytesIO()
            np.save(original,np.ones((1,3,1,1),np.float32),allow_pickle=False)
            original_bytes = original.getvalue()
            path.write_bytes(original_bytes)
            frozen = freeze_files((path,))
            with path.open("wb") as stream:
                np.save(stream,np.full((1,3,1,1),2,np.float32),allow_pickle=False)
            decoded = load_npy(frozen[str(path)])
            path.write_bytes(original_bytes)
            verify_files(frozen)
            np.testing.assert_array_equal(decoded,np.ones((1,3,1,1),np.float32))

    def test_raster_orientation_matches_every_pixel_centre_mapping(self):
        image = np.arange(24,dtype=np.float32).reshape(1,1,4,6)/24
        image = np.repeat(image,3,axis=1)
        # Disable resizing only in this geometry test, so each original marker
        # can be tracked exactly through the production preparation operations.
        with patch("PIL.Image.Image.resize",lambda self,*args,**kwargs:self):
            for orientation in range(1,9):
                for turns in range(4):
                    frame = PromptFrame(SOURCE,6,4,orientation,turns=turns)
                    prepared = prepare_segnext(image,frame)
                    fw,fh = frame.frame_size
                    self.assertEqual(prepared.shape,(1,3,fh,fw))
                    for y in range(4):
                        for x in range(6):
                            px,py = frame.to_prompt((x+.5,y+.5),source_sha256=SOURCE,frame_id=frame.identity)
                            self.assertEqual(prepared[0,0,int(py*fh/1024),int(px*fw/1024)],image[0,0,y,x])

    def test_projection_inverse_orientation_and_crop(self):
        for orientation in range(1,9):
            for turns in range(4):
                frame = PromptFrame(SOURCE,8,6,orientation,turns=turns)
                full = project_segnext(np.ones((1,1,1024,1024),np.float32),frame)
                self.assertEqual(full.shape,(1,1,6,8))
                self.assertTrue(full.all())
        frame = PromptFrame(SOURCE,8,6,crop=(2,2,4,2),turns=3)
        out = project_segnext(np.ones((1,1,1024,1024),np.float32),frame)
        expected = np.zeros((1,1,6,8),np.float32)
        expected[:,:,2:4,2:6] = 1
        np.testing.assert_array_equal(out,expected)

    def test_iou_empty_union_and_binary_gt(self):
        self.assertEqual(binary_iou(np.zeros((2,2)),np.zeros((2,2))),1)
        self.assertEqual(binary_iou(np.array([1,0]),np.array([1,1])),.5)
        with self.assertRaises(ValueError):
            binary_iou(np.array([.5]),np.array([1]))

    def test_identity_tiles_singleton_small_odd_and_multiple_cores(self):
        for h,w in ((1,1),(1,5),(5,1),(17,19),(33,35)):
            arr = np.arange(3*h*w,dtype=np.float32).reshape(1,3,h,w)
            out = tiled(arr,lambda x:x.copy(),tile_size=16,overlap=3)
            np.testing.assert_array_equal(out,arr)

    def test_double_output_keeps_last_sensor_rows_and_columns(self):
        arr = np.arange(4*17*19,dtype=np.float32).reshape(1,4,17,19)
        def fake(patch):
            return np.repeat(np.repeat(patch[:,:3],2,axis=2),2,axis=3)
        out = tiled(arr,fake,tile_size=16,overlap=3,scale=2)
        np.testing.assert_array_equal(out,fake(arr))
        self.assertEqual(out.shape,(1,3,34,38))

    def test_mirror_indices_match_numpy_reflect(self):
        for length in (1,2,5):
            expected = np.pad(np.arange(length),(20,20),mode="reflect")
            np.testing.assert_array_equal(mirror_indices(-20,length+40,length),expected)

    def test_tensor_budget_checked_before_inference(self):
        with self.assertRaises(ValueError):
            tiled(np.zeros((1,3,17,19),np.float32),lambda _:self.fail("must not run"),tile_size=16,overlap=3,max_tensor_bytes=10)

    def test_cancellation_waits_for_native_return_then_discards(self):
        state = {"cancelled":False,"returned":False}
        def infer(patch):
            state.update(cancelled=True,returned=True)
            return patch
        with self.assertRaises(InterruptedError):
            tiled(np.zeros((1,3,2,2),np.float32),infer,tile_size=16,overlap=3,cancelled=lambda:state["cancelled"])
        self.assertTrue(state["returned"])

    def test_nonfinite_wrongshape_and_precision_outputs_rejected(self):
        arr = np.zeros((1,3,2,2),np.float32)
        for infer in (lambda x:x.astype(np.float16),lambda x:x[:,:,:-1],lambda x:x+np.float32(np.nan)):
            with self.assertRaises(ValueError):
                tiled(arr,infer,tile_size=16,overlap=3)

    def test_sdr_transfer_roundtrip_and_hdr_rejection(self):
        arr = np.linspace(0,1,33,dtype=np.float32).reshape(1,3,1,11)
        np.testing.assert_allclose(transfer(transfer(arr,to_encoded=True),to_encoded=False),arr,atol=2e-7)
        for value in (-.001,1.001,float("nan")):
            with self.assertRaises(ValueError):
                transfer(np.full((1,3,1,1),value,np.float32),to_encoded=True)

    def test_exact_alpha_preservation(self):
        rgb = np.zeros((1,3,1,3),np.float32)
        alpha = np.array([[[[0,.33,1]]]],np.float32)
        self.assertEqual(preserve_alpha(rgb,alpha)[:,3:].tobytes(),alpha.tobytes())

    def test_gain_matching_positive_and_nonphysical_means(self):
        anchor = np.ones((1,4,2,2),np.float32)
        for value in (.5,2):
            out,gain = match_gain(np.full((1,3,4,4),value,np.float32),anchor)
            np.testing.assert_array_equal(out,np.ones_like(out))
            self.assertEqual(gain,1/value)
        for value in (-.5,0,float("nan"),float("inf")):
            with self.assertRaises(ValueError):
                match_gain(np.full((1,3,1,1),value,np.float32),anchor)
        with self.assertRaises(ValueError):
            match_gain(np.ones((1,3,1,1),np.float32),np.zeros_like(anchor))

    def test_bayer_levels_phase_active_area_and_no_source_mutation(self):
        mosaic = np.arange(8*10,dtype=np.float32).reshape(8,10)
        original = mosaic.copy()
        result = pack_bayer(mosaic,pattern=(("R","G1"),("G2","B")),black=[0,1,2,3],white=[100]*4,active_area=(2,2,6,4))
        self.assertEqual(result.shape,(1,4,2,3))
        self.assertAlmostEqual(float(result[0,0,0,0]),22/100)
        self.assertAlmostEqual(float(result[0,1,0,0]),22/99)
        np.testing.assert_array_equal(mosaic,original)
        with self.assertRaises(ValueError):
            pack_bayer(mosaic,pattern=(("R","G1"),("G2","B")),black=[0]*4,white=[100]*4,active_area=(1,0,6,4))

    def test_unsupported_cfa_orientation_and_levels_refused(self):
        for change in ({"orientation":6},{"pattern":(("R","G"),("G","B"))},{"white":[0]*4}):
            options=dict(pattern=(("R","G1"),("G2","B")),black=[0]*4,white=[100]*4,active_area=(0,0,4,4))
            options.update(change)
            with self.assertRaises(ValueError):
                pack_bayer(np.zeros((4,4),np.float32),**options)

    def test_camera_matrix_never_guessed(self):
        rgb = np.ones((1,3,2,2),np.float32)
        for matrix in (np.zeros((3,3)),np.ones((2,3)),np.full((3,3),np.nan)):
            with self.assertRaises(ValueError):
                camera_to_rec2020(rgb,matrix)
        self.assertTrue(np.isfinite(camera_to_rec2020(rgb,np.eye(3))).all())


@unittest.skipIf(np is None,"NumPy required for research adapter smoke tests")
class SegNextTests(unittest.TestCase):
    class Fake:
        sha256 = "c"*64
        def __init__(self,encoder=False):
            self.calls,self.encoder,self.prev = 0,encoder,None
        def run(self,values):
            self.calls += 1
            if self.encoder:
                return [np.zeros((1,768,64,64),np.float32)]
            self.prev = values["prev_mask"].copy()
            return [np.ones((1,1,1024,1024),np.float32)]

    def setup_adapter(self,cache_bytes=32*1024*1024):
        enc,dec = self.Fake(True),self.Fake()
        return SegNext(enc,dec,cache_bytes),enc,dec

    def click(self,frame,label=1,point=(20,30)):
        return dict(point=point,label=label,source_sha256=SOURCE,frame_id=frame.identity)

    def test_encoder_reused_decoder_only_and_binary_feedback(self):
        adapter,enc,dec = self.setup_adapter()
        frame = PromptFrame(SOURCE,600,400)
        image = np.zeros((1,3,1024,1024),np.float32)
        clicks = [self.click(frame)]
        first = adapter.refine(image,frame,clicks)
        self.assertFalse(dec.prev.any())
        second = adapter.refine(image,frame,clicks+[self.click(frame,0,(40,50))],previous=first)
        self.assertEqual(enc.calls,1)
        self.assertEqual(dec.calls,2)
        np.testing.assert_array_equal(dec.prev,np.ones_like(dec.prev))
        np.testing.assert_array_equal(second["binary"],np.ones_like(second["binary"]))

    def test_source_switch_and_history_changes_reject_previous(self):
        adapter,_,_ = self.setup_adapter()
        frame = PromptFrame(SOURCE,600,400)
        image = np.zeros((1,3,1024,1024),np.float32)
        first = adapter.refine(image,frame,[self.click(frame)])
        for clicks in ([self.click(frame,0)],[self.click(frame),self.click(frame),self.click(frame)]):
            with self.assertRaises(ValueError):
                adapter.refine(image,frame,clicks,previous=first)
        with self.assertRaises(ValueError):
            adapter.refine(image+.1,frame,[self.click(frame)],previous=first)

    def test_logits_or_start_matte_cannot_be_prev_mask(self):
        adapter,_,_ = self.setup_adapter()
        frame = PromptFrame(SOURCE,600,400)
        image = np.zeros((1,3,1024,1024),np.float32)
        clicks = [self.click(frame)]
        first = adapter.refine(image,frame,clicks)
        first["binary"][:] = .2
        with self.assertRaises(ValueError):
            adapter.refine(image,frame,clicks+[self.click(frame,0)],previous=first)

    def test_cache_eviction_and_disabled_cache(self):
        for budget in (0,13*1024*1024):
            adapter,enc,_ = self.setup_adapter(budget)
            frame = PromptFrame(SOURCE,600,400)
            image = np.zeros((1,3,1024,1024),np.float32)
            for value in (0,.1,0):
                adapter.refine(image+value,frame,[self.click(frame)])
            self.assertEqual(enc.calls,3)
            self.assertLessEqual(sum(v.nbytes for v in adapter.cache.values()),budget)

    def test_decoder_cancellation_never_publishes_proposal(self):
        adapter,_,dec = self.setup_adapter()
        frame = PromptFrame(SOURCE,600,400)
        with self.assertRaises(InterruptedError):
            adapter.refine(np.zeros((1,3,1024,1024),np.float32),frame,[self.click(frame)],cancelled=lambda:dec.calls > 0)


if __name__ == "__main__":
    unittest.main()

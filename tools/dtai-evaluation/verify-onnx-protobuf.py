#!/usr/bin/env python3
"""Real protobuf contract check; creates no model session and performs no inference."""
import json
import onnx
from google.protobuf import __version__ as protobuf_version
from onnx import helper, TensorProto
from adapters import reject_external_data


def model_with(tensor):
    return helper.make_model(helper.make_graph([], "test", [], [], initializer=[tensor]))


def must_reject(model):
    try:
        reject_external_data(model.SerializeToString())
    except ValueError as error:
        if "ExternalData" not in str(error):
            raise
    else:
        raise AssertionError("unbound external weights admitted")


inline = helper.make_tensor("inline", TensorProto.FLOAT, [1], [1.])
reject_external_data(model_with(inline).SerializeToString())
external = TensorProto(name="external", data_type=TensorProto.FLOAT, dims=[1], data_location=TensorProto.EXTERNAL)
entry = external.external_data.add()
entry.key, entry.value = "location", "unbound.bin"
must_reject(model_with(external))
inner = helper.make_graph([], "inner", [], [], initializer=[external])
outer = helper.make_graph([helper.make_node("If", ["condition"], ["out"], then_branch=inner, else_branch=inner)], "outer", [], [])
must_reject(helper.make_model(outer))
sparse = onnx.SparseTensorProto()
sparse.values.CopyFrom(external)
sparse.indices.CopyFrom(helper.make_tensor("indices", TensorProto.INT64, [1], [0]))
sparse.dims.extend([1])
graph = helper.make_graph([], "sparse", [], [])
graph.sparse_initializer.append(sparse)
must_reject(helper.make_model(graph))
print(json.dumps({"checks": 4, "onnx": onnx.__version__, "protobuf": protobuf_version,
                  "result": "inline accepted; direct/nested/sparse ExternalData rejected", "model_inference": False}))

#!/usr/bin/env python3
"""Numerically check exact deform-conv conversion with nonzero offsets/masks."""
import json
import numpy as np
import torch
import torchvision.ops
import coremltools as ct

from deform_conv_grid_sample import register_deform_conv2d_real
from validation import compare


class Probe(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("weight", torch.randn(3, 4, 3, 3))
        self.register_buffer("bias", torch.randn(3))

    def forward(self, x, offset, mask):
        return torchvision.ops.deform_conv2d(x, offset, self.weight, self.bias,
                                            padding=1, mask=mask)


torch.manual_seed(8724)
inputs = (torch.randn(1, 4, 7, 5), torch.randn(1, 18, 7, 5), torch.rand(1, 9, 7, 5) * 2)
model = Probe().eval()
with torch.inference_mode():
    expected = model(*inputs).numpy()
    traced = torch.jit.trace(model, inputs)
register_deform_conv2d_real()
converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                       inputs=[ct.TensorType(name=name, shape=value.shape) for name, value in
                               zip(("x", "offset", "mask"), inputs)],
                       outputs=[ct.TensorType(name="output")],
                       compute_precision=ct.precision.FLOAT32,
                       compute_units=ct.ComputeUnit.CPU_ONLY)
actual = converted.predict(dict(zip(("x", "offset", "mask"), (x.numpy() for x in inputs))))["output"]
errors = {"offset-and-mask": compare(expected, actual, maximum_limit=1e-4)["maximumAbsoluteError"]}
for label, offset, mask in [("zero", inputs[1] * 0, inputs[2] * 0 + 1),
                            ("offset-only", inputs[1], inputs[2] * 0 + 1),
                            ("mask-only", inputs[1] * 0, inputs[2])]:
    with torch.inference_mode():
        expected_probe = model(inputs[0], offset, mask).numpy()
    actual_probe = converted.predict({"x": inputs[0].numpy(), "offset": offset.numpy(), "mask": mask.numpy()})["output"]
    errors[label] = compare(expected_probe, actual_probe, maximum_limit=1e-4)["maximumAbsoluteError"]
maximum = max(errors.values())
print(json.dumps({"maximumAbsoluteError": maximum, "errors": errors, "shape": list(actual.shape)}))
if maximum > 1e-4:
    raise SystemExit("Deform-conv conversion changed learned sampling")

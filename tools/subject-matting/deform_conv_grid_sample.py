"""Adapted from imperatormk/coreml-birefnet (MIT, LICENSE-coreml-birefnet).

Register torchvision::deform_conv2d as a grid_sample-based decomposition that
preserves the learned offsets (and mask, if used). Output is numerically
equivalent to torchvision's deform_conv2d for 3x3 deform.

Approach (standard deform-conv decomposition):
  1. For each kernel location (i,j) in [0..kH-1] x [0..kW-1], compute the
     sampling grid for that tap from base position + learned offset.
  2. grid_sample the input with that grid -> sampled feature map per tap.
  3. Multiply by mask (if modulated) and by the conv weight slice for that tap.
  4. Sum over all taps -> output.
"""
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.torch_op_registry import (
    _TORCH_OPS_REGISTRY, register_torch_op,
)
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
import numpy as np


def register_deform_conv2d_real():
    if "torchvision::deform_conv2d" in _TORCH_OPS_REGISTRY:
        del _TORCH_OPS_REGISTRY["torchvision::deform_conv2d"]

    @register_torch_op(torch_alias=["torchvision::deform_conv2d"])
    def torchvision_deform_conv2d(context, node):
        inputs = _get_inputs(context, node)
        # Signature: input, weight, offset, mask, bias, sH, sW, pH, pW, dH, dW, groups, offset_groups, use_mask
        x      = inputs[0]
        weight = inputs[1]
        offset = inputs[2]
        mask   = inputs[3] if len(inputs) > 3 else None
        bias   = inputs[4] if len(inputs) > 4 and inputs[4] is not None else None

        def s(idx, default):
            inp = inputs[idx] if len(inputs) > idx else None
            if inp is None:
                return default
            v = inp.val
            if hasattr(v, "__len__") and len(v) > 0:
                return int(v[0]) if v[0] != 0 else default
            return int(v) if v != 0 else default

        sH, sW = s(5, 1), s(6, 1)
        pH, pW = s(7, 0), s(8, 0)
        dH, dW = s(9, 1), s(10, 1)
        groups = s(11, 1)
        offset_groups = s(12, 1)
        use_mask = s(13, 0)

        # Static shapes — required for grid construction.
        x_shape = x.shape         # (B, Cin, Hin, Win)
        w_shape = weight.shape    # (Cout, Cin/groups, kH, kW)
        B, Cin, Hin, Win = x_shape
        Cout, Cin_per_group, kH, kW = w_shape
        # The pinned BiRefNet only uses one offset group. Refuse unsupported
        # graphs instead of silently reusing the first group's learned offsets.
        if offset_groups != 1 or groups != 1 or B != 1:
            raise ValueError("Glowroom conversion only supports batch=groups=offset_groups=1")

        # Output spatial size (deform_conv2d formula)
        Hout = (Hin + 2 * pH - dH * (kH - 1) - 1) // sH + 1
        Wout = (Win + 2 * pW - dW * (kW - 1) - 1) // sW + 1

        # offset shape: (B, offset_groups * 2 * kH * kW, Hout, Wout)
        # mask   shape: (B, offset_groups * kH * kW, Hout, Wout)

        # Base sampling grid for one tap: position of output (yo,xo) projected
        # back to input coords with stride/pad/dilation, plus kernel offset.
        # For tap (i,j): base_y = yo*sH - pH + i*dH, base_x = xo*sW - pW + j*dW
        # With learned offset: y = base_y + off_y, x = base_x + off_x
        # grid_sample expects normalized coords in [-1, 1]:
        #   y_norm = 2*y/(Hin-1) - 1, x_norm = 2*x/(Win-1) - 1

        # Precompute base grid for all taps as constants:
        # base[i,j,yo,xo] = (base_y, base_x)
        yo_idx = np.arange(Hout, dtype=np.float32)
        xo_idx = np.arange(Wout, dtype=np.float32)

        # We process taps in order (i,j) flattened to k=0..kH*kW-1.
        accumulated = None
        for i in range(kH):
            for j in range(kW):
                k = i * kW + j
                base_y = yo_idx * sH - pH + i * dH    # (Hout,)
                base_x = xo_idx * sW - pW + j * dW    # (Wout,)
                base_y_grid = np.broadcast_to(base_y[:, None], (Hout, Wout)).astype(np.float32)
                base_x_grid = np.broadcast_to(base_x[None, :], (Hout, Wout)).astype(np.float32)
                base_y_const = mb.const(val=base_y_grid, name=f"{node.name}_basey_{k}")
                base_x_const = mb.const(val=base_x_grid, name=f"{node.name}_basex_{k}")

                # Slice the offset: channels [2k : 2k+2] for each offset_group.
                # For offset_groups=1 (typical), offset_channels = 2*kH*kW.
                # off_y at channel 2k, off_x at channel 2k+1.
                off_y = mb.slice_by_index(
                    x=offset,
                    begin=[0, 2*k,     0, 0],
                    end=  [B, 2*k + 1, Hout, Wout],
                    name=f"{node.name}_offy_{k}",
                )  # (B, 1, Hout, Wout)
                off_x = mb.slice_by_index(
                    x=offset,
                    begin=[0, 2*k + 1, 0, 0],
                    end=  [B, 2*k + 2, Hout, Wout],
                    name=f"{node.name}_offx_{k}",
                )  # (B, 1, Hout, Wout)
                # Squeeze channel dim -> (B, Hout, Wout)
                off_y = mb.squeeze(x=off_y, axes=[1], name=f"{node.name}_offys_{k}")
                off_x = mb.squeeze(x=off_x, axes=[1], name=f"{node.name}_offxs_{k}")

                # Add base + offset, normalize to [-1, 1]
                y = mb.add(x=off_y, y=base_y_const, name=f"{node.name}_y_{k}")
                x_pos = mb.add(x=off_x, y=base_x_const, name=f"{node.name}_x_{k}")
                y_norm = mb.mul(x=y, y=2.0/(Hin-1), name=f"{node.name}_yn0_{k}")
                y_norm = mb.sub(x=y_norm, y=1.0, name=f"{node.name}_yn_{k}")
                x_norm = mb.mul(x=x_pos, y=2.0/(Win-1), name=f"{node.name}_xn0_{k}")
                x_norm = mb.sub(x=x_norm, y=1.0, name=f"{node.name}_xn_{k}")

                # Stack to grid (B, Hout, Wout, 2) with last dim = (x, y) for resample
                # CoreML resample uses (x, y) order in coordinates.
                x_norm_e = mb.expand_dims(x=x_norm, axes=[-1], name=f"{node.name}_xne_{k}")
                y_norm_e = mb.expand_dims(x=y_norm, axes=[-1], name=f"{node.name}_yne_{k}")
                grid = mb.concat(values=[x_norm_e, y_norm_e], axis=-1,
                                 name=f"{node.name}_grid_{k}")  # (B, Hout, Wout, 2)

                # resample = grid_sample bilinear, zeros padding, align_corners=True
                sampled = mb.resample(
                    x=x,
                    coordinates=grid,
                    sampling_mode="bilinear",
                    padding_mode="constant",
                    padding_value=0.0,
                    coordinates_mode="normalized_minus_one_to_one",
                    align_corners=True,
                    name=f"{node.name}_samp_{k}",
                )  # (B, Cin, Hout, Wout)

                # Apply mask if modulated deform conv
                if use_mask and mask is not None:
                    m = mb.slice_by_index(
                        x=mask,
                        begin=[0, k,     0, 0],
                        end=  [B, k + 1, Hout, Wout],
                        name=f"{node.name}_msl_{k}",
                    )  # (B, 1, Hout, Wout)
                    sampled = mb.mul(x=sampled, y=m, name=f"{node.name}_msamp_{k}")

                # Apply weight slice for this tap: w[:, :, i, j] -> (Cout, Cin/groups, 1, 1)
                # Use 1x1 conv with this weight slice on the sampled feature.
                w_slice = mb.slice_by_index(
                    x=weight,
                    begin=[0, 0, i, j],
                    end=  [Cout, Cin_per_group, i+1, j+1],
                    name=f"{node.name}_ws_{k}",
                )  # (Cout, Cin/groups, 1, 1)

                # 1x1 conv: input (B, Cin, Hout, Wout), weight (Cout, Cin/g, 1, 1)
                # bias only on the LAST tap accumulation
                tap_out = mb.conv(
                    x=sampled,
                    weight=w_slice,
                    strides=[1, 1],
                    pad=[0, 0, 0, 0],
                    pad_type="custom",
                    dilations=[1, 1],
                    groups=groups,
                    name=f"{node.name}_tc_{k}",
                )

                if accumulated is None:
                    accumulated = tap_out
                else:
                    accumulated = mb.add(x=accumulated, y=tap_out,
                                         name=f"{node.name}_acc_{k}")

        if bias is not None:
            # bias shape (Cout,) -> reshape to (1, Cout, 1, 1) for broadcast
            bias_r = mb.reshape(x=bias, shape=[1, Cout, 1, 1],
                                name=f"{node.name}_biasr")
            accumulated = mb.add(x=accumulated, y=bias_r, name=node.name)
        else:
            accumulated = mb.identity(x=accumulated, name=node.name)
        context.add(accumulated)

    print("[convert] registered REAL deform_conv2d via grid_sample")

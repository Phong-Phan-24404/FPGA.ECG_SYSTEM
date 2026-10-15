"""
ecg_fixed -- bit-true fixed-point primitives and forward pass for the ECG 1D-CNN.

A self-contained port of FPGA_CNN/models/common/fixed_ops.py and
models/fixed/model_fixed.py, so this folder can generate samples without the
training tree on PYTHONPATH. The arithmetic is reproduced exactly, because its
whole purpose is to agree bit-for-bit with the RTL:

  activations  Q8.8   (act_frac = 8,  16-bit signed)
  weights      Q2.14  (w_frac   = 14, 16-bit signed)
  accumulate   full precision, then round-half-up and saturate back to 16 bits

Two details are easy to get wrong and are kept deliberately:

  * to_fixed uses np.round, which is round-half-to-EVEN. The re-quantisation
    inside a layer uses (acc + (1 << (shift-1))) >> shift, which is round-half-
    UP. They differ, and the RTL implements both in those same places.
  * the bias is stored at w_frac but the accumulator is at x_frac + w_frac, so
    the bias is shifted up before being added, never rounded down to meet it.
"""
from __future__ import annotations

import numpy as np

ACT_FRAC = 8      # Q8.8 activations, including the input
W_FRAC = 14       # Q2.14 weights and biases
TOTAL_BITS = 16

N_INPUTS = 187
N_CLASSES = 5
CLASS_CODES = ["N", "S", "V", "F", "Q"]
CLASS_NAMES = {
    "N": "Normal",
    "S": "Supraventricular ectopic",
    "V": "Ventricular ectopic",
    "F": "Fusion",
    "Q": "Unknown / paced",
}


# ------------------------------------------------------------ primitives ----
def to_fixed(val, frac_bits: int, total_bits: int = TOTAL_BITS) -> np.ndarray:
    """Float -> fixed-point integer, round-to-nearest-even then saturate."""
    scaled = np.round(np.asarray(val, dtype=np.float64) * (2.0 ** frac_bits))
    lo = -(1 << (total_bits - 1))
    hi = (1 << (total_bits - 1)) - 1
    return np.clip(scaled, lo, hi).astype(np.int64)


def to_float(val, frac_bits: int) -> np.ndarray:
    return np.asarray(val).astype(np.float64) / (2.0 ** frac_bits)


def saturate(val, total_bits: int = TOTAL_BITS) -> np.ndarray:
    lo = -(1 << (total_bits - 1))
    hi = (1 << (total_bits - 1)) - 1
    return np.clip(val, lo, hi)


def round_and_scale(val, shift: int, total_bits: int = TOTAL_BITS) -> np.ndarray:
    """Re-quantise an accumulator: round-half-up on a right shift, then saturate."""
    if shift > 0:
        rounded = (val + (1 << (shift - 1))) >> shift
    elif shift < 0:
        rounded = val << (-shift)
    else:
        rounded = val
    return saturate(rounded, total_bits)


def _align_bias(b, x_frac: int, w_frac: int, b_frac: int):
    shift = (x_frac + w_frac) - b_frac
    if shift > 0:
        return b << shift
    if shift < 0:
        return b >> (-shift)
    return b


def fixed_conv1d(x, w, b, x_frac, w_frac, b_frac, out_frac,
                 total_bits: int = TOTAL_BITS) -> np.ndarray:
    """x (N, C_in, L) * w (C_out, C_in, K) -> (N, C_out, L-K+1). Stride 1, no pad."""
    x = np.ascontiguousarray(x, dtype=np.int64)
    batch, in_channels, in_len = x.shape
    out_channels, _, kernel = w.shape
    out_len = in_len - kernel + 1

    windows = np.lib.stride_tricks.as_strided(
        x,
        shape=(batch, out_len, in_channels, kernel),
        strides=(x.strides[0], x.strides[2], x.strides[1], x.strides[2]),
    )
    acc = np.tensordot(windows, w, axes=((2, 3), (1, 2)))      # (N, L_out, C_out)
    acc = np.transpose(acc, (0, 2, 1))                          # (N, C_out, L_out)
    acc = acc + _align_bias(b, x_frac, w_frac, b_frac)[:, None]
    return round_and_scale(acc, (x_frac + w_frac) - out_frac, total_bits)


def fixed_relu(x):
    return np.maximum(x, 0)


def fixed_maxpool1d(x, kernel_size: int = 2, stride: int = 2) -> np.ndarray:
    batch, channels, length = x.shape
    out_len = (length - kernel_size) // stride + 1
    y = np.zeros((batch, channels, out_len), dtype=np.int64)
    for t in range(out_len):
        start = t * stride
        y[:, :, t] = np.max(x[:, :, start:start + kernel_size], axis=2)
    return y


def fixed_global_maxpool1d(x):
    return np.max(x, axis=2, keepdims=True)


def fixed_linear(x, w, b, x_frac, w_frac, b_frac, out_frac,
                 total_bits: int = TOTAL_BITS) -> np.ndarray:
    acc = np.dot(x, w.T) + _align_bias(b, x_frac, w_frac, b_frac)[None, :]
    return round_and_scale(acc, (x_frac + w_frac) - out_frac, total_bits)


# ----------------------------------------------------------------- model ----
def _normalise_key(key: str) -> str:
    """'conv1.weight' and 'conv1__weight' both name conv1_weight."""
    return key.replace(".", "_").replace("__", "_")


class FixedECG1DCNN:
    """The quantised network, in integers, layer for layer as the RTL builds it."""

    def __init__(self, weights_npz: str, act_frac: int = ACT_FRAC, w_frac: int = W_FRAC):
        self.act_frac = act_frac
        self.w_frac = w_frac
        with np.load(weights_npz) as data:
            self.w = {_normalise_key(k): to_fixed(data[k], w_frac) for k in data.files}

    def forward_int(self, x_float) -> tuple:
        """x_float (187,) or (1, 187) -> (logits int16, activations dict)."""
        x_float = np.asarray(x_float, dtype=np.float64).reshape(1, 1, N_INPUTS)
        af, wf, w = self.act_frac, self.w_frac, self.w

        x = to_fixed(x_float, af)
        acts = {"input": x}

        x = fixed_conv1d(x, w["conv1_weight"], w["conv1_bias"], af, wf, wf, af); acts["conv1"] = x
        x = fixed_relu(x); acts["relu1"] = x
        x = fixed_conv1d(x, w["conv2_weight"], w["conv2_bias"], af, wf, wf, af); acts["conv2"] = x
        x = fixed_relu(x); acts["relu2"] = x
        x = fixed_maxpool1d(x); acts["pool1"] = x

        x = fixed_conv1d(x, w["conv3_weight"], w["conv3_bias"], af, wf, wf, af); acts["conv3"] = x
        x = fixed_relu(x); acts["relu3"] = x
        x = fixed_conv1d(x, w["conv4_weight"], w["conv4_bias"], af, wf, wf, af); acts["conv4"] = x
        x = fixed_relu(x); acts["relu4"] = x
        x = fixed_maxpool1d(x); acts["pool2"] = x

        x = fixed_conv1d(x, w["conv5_weight"], w["conv5_bias"], af, wf, wf, af); acts["conv5"] = x
        x = fixed_relu(x); acts["relu5"] = x
        x = fixed_conv1d(x, w["conv6_weight"], w["conv6_bias"], af, wf, wf, af); acts["conv6"] = x
        x = fixed_relu(x); acts["relu6"] = x

        x = fixed_global_maxpool1d(x); acts["global_max_pool"] = x
        x = x.squeeze(2); acts["flatten"] = x

        x = fixed_linear(x, w["fc1_weight"], w["fc1_bias"], af, wf, wf, af); acts["fc1"] = x
        x = fixed_relu(x); acts["relu7"] = x
        x = fixed_linear(x, w["fc2_weight"], w["fc2_bias"], af, wf, wf, af); acts["fc2"] = x
        x = fixed_relu(x); acts["relu8"] = x
        logits = fixed_linear(x, w["fc3_weight"], w["fc3_bias"], af, wf, wf, af)
        acts["logits"] = logits

        return logits.reshape(-1), acts


# ------------------------------------------------------------------ hex ----
def to_hex16(value: int) -> str:
    """Signed integer -> 16-bit two's complement, uppercase, as $readmemh wants."""
    return "%04X" % (int(value) & 0xFFFF)


def write_hex(path, values) -> None:
    with open(path, "w", newline="\n") as handle:
        for value in np.asarray(values).reshape(-1):
            handle.write(to_hex16(value) + "\n")

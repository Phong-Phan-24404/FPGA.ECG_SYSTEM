#!/usr/bin/env python3
"""
ecg_cpu_worker -- FP32 ECG 1D-CNN inference served over stdin/stdout.

The Qt app starts this once and keeps it alive, then sends one beat per line.
Spawning a fresh interpreter per beat would cost far more in Python start-up,
NumPy import and weight loading than the inference itself, so the process is
long-lived and the per-beat cost is just pipe I/O plus the forward pass.

Protocol, line-oriented and flushed after every reply:

    <- READY <n_inputs> <n_classes>      once, at start-up
    -> 187 space-separated floats        one request
    <- OK <5 space-separated logits>     success
    <- ERR <message>                     recoverable; the worker stays up

Anything on stderr is diagnostics for the host, never part of the protocol.

The graph is the same transcription of models/float/golden_model.py used by
app2, validated against the recorded PyTorch logits (max |diff| 3.8e-06 over
128 samples, 128/128 argmax agreement). BatchNorm and Dropout are absent
because the reference is built with use_batch_norm=False and dropout is
identity in eval mode.
"""
from __future__ import annotations

import os
import sys

import numpy as np

N_INPUTS = 187
N_CLASSES = 5

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WEIGHTS = os.path.join(HERE, "weights", "ecg1dcnn_weights_float32.npz")


# ---------------------------------------------------------------- layers ----
def conv1d(x, w, b):
    """x (C_in, L) -> (C_out, L-K+1). Stride 1, no padding."""
    c_in, length = x.shape
    c_out, _, k = w.shape
    l_out = length - k + 1
    s = x.strides
    # im2col: one large contiguous multiply instead of ~10^5 interpreted dots.
    patches = np.lib.stride_tricks.as_strided(
        x, shape=(c_in, k, l_out), strides=(s[0], s[1], s[1])
    ).reshape(c_in * k, l_out)
    return w.reshape(c_out, c_in * k) @ patches + b[:, None]


def relu(x):
    return np.maximum(x, 0.0, dtype=np.float32)


def maxpool1d(x, k=2, s=2):
    c, length = x.shape
    l_out = (length - k) // s + 1
    st = x.strides
    win = np.lib.stride_tricks.as_strided(
        x, shape=(c, l_out, k), strides=(st[0], st[1] * s, st[1])
    )
    return win.max(axis=2)


def linear(x, w, b):
    return w @ x + b


# ----------------------------------------------------------------- model ----
class ECG1DCNN:
    def __init__(self, weights):
        self.w = {k: np.ascontiguousarray(v, dtype=np.float32)
                  for k, v in weights.items()}

    def forward(self, x):
        """x is (1, 187) float32 -> logits (5,)."""
        g = self.w
        x = relu(conv1d(x, g["conv1__weight"], g["conv1__bias"]))
        x = relu(conv1d(x, g["conv2__weight"], g["conv2__bias"]))
        x = maxpool1d(x)
        x = relu(conv1d(x, g["conv3__weight"], g["conv3__bias"]))
        x = relu(conv1d(x, g["conv4__weight"], g["conv4__bias"]))
        x = maxpool1d(x)
        x = relu(conv1d(x, g["conv5__weight"], g["conv5__bias"]))
        x = relu(conv1d(x, g["conv6__weight"], g["conv6__bias"]))
        x = x.max(axis=1)                       # AdaptiveMaxPool1d(1) + flatten
        x = relu(linear(x, g["fc1__weight"], g["fc1__bias"]))
        x = relu(linear(x, g["fc2__weight"], g["fc2__bias"]))
        return linear(x, g["fc3__weight"], g["fc3__bias"])


def main() -> int:
    path = os.environ.get("ECG_CPU_WEIGHTS", DEFAULT_WEIGHTS)
    if not os.path.exists(path):
        # Fail before READY: the host treats a missing handshake as "not loaded"
        # and reports it, rather than hanging.
        sys.stderr.write("weights not found: %s\n" % path)
        return 1
    try:
        with np.load(path) as z:
            model = ECG1DCNN({k: z[k] for k in z.files})
    except Exception as exc:                      # noqa: BLE001 - reported to host
        sys.stderr.write("failed to load weights: %s\n" % exc)
        return 1

    # Touch every layer once so the first real beat does not pay for lazily
    # allocated temporaries; the host measures that beat like any other.
    model.forward(np.zeros((1, N_INPUTS), dtype=np.float32))

    sys.stdout.write("READY %d %d\n" % (N_INPUTS, N_CLASSES))
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        if line == "QUIT":
            return 0
        try:
            values = np.asarray(line.split(), dtype=np.float32)
            if values.size != N_INPUTS:
                raise ValueError("expected %d samples, got %d"
                                 % (N_INPUTS, values.size))
            logits = model.forward(values.reshape(1, N_INPUTS))
            sys.stdout.write("OK " + " ".join("%.7g" % v for v in logits) + "\n")
        except Exception as exc:                  # noqa: BLE001 - recoverable
            sys.stdout.write("ERR %s\n" % str(exc).replace("\n", " "))
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())

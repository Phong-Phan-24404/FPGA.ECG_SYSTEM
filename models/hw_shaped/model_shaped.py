#!/usr/bin/env python3
"""Hardware-shaped bit-true streaming 1D CNN reference model.

Simulates sequential line buffers, shift registers, and cycle-by-cycle memory
access patterns to match the upcoming synthesizable RTL design.
"""

import os
import json
import numpy as np
from typing import Dict, Tuple

from models.common.fixed_ops import to_fixed, to_float, round_and_scale

class ShiftRegister1D:
    """Simulates a hardware shift register for sliding window operations."""
    def __init__(self, channels: int, size: int):
        self.channels = channels
        self.size = size
        self.buffer = np.zeros((channels, size), dtype=np.int64)
        
    def shift_in(self, x_col: np.ndarray):
        # Shift left by 1 column and insert new column at the right (LSB/newest)
        self.buffer[:, :-1] = self.buffer[:, 1:]
        self.buffer[:, -1] = x_col

def stream_conv1d(
    x_stream: np.ndarray,  # (in_channels, in_len)
    w: np.ndarray,         # (out_channels, in_channels, kernel_size)
    b: np.ndarray,         # (out_channels,)
    x_frac: int,
    w_frac: int,
    b_frac: int,
    out_frac: int,
    total_bits: int = 16
) -> np.ndarray:
    """Streaming hardware-shaped 1D Convolution."""
    in_channels, in_len = x_stream.shape
    out_channels, _, kernel_size = w.shape
    out_len = in_len - kernel_size + 1
    
    y = np.zeros((out_channels, out_len), dtype=np.int64)
    reg = ShiftRegister1D(in_channels, kernel_size)
    
    out_idx = 0
    # Stream data sample by sample (cycle by cycle)
    for t in range(in_len):
        reg.shift_in(x_stream[:, t])
        
        # Once the shift register has filled with kernel_size samples, output is valid
        if t >= kernel_size - 1:
            # Vectorized MAC over channels and kernel keys to bypass slow Python loops
            acc = np.sum(reg.buffer[None, :, :] * w, axis=(1, 2))
            
            # Align bias to product fractional format (x_frac + w_frac)
            bias_shift = (x_frac + w_frac) - b_frac
            if bias_shift > 0:
                aligned_bias = b << bias_shift
            elif bias_shift < 0:
                aligned_bias = b >> (-bias_shift)
            else:
                aligned_bias = b
                
            acc_total = acc + aligned_bias
            
            # Round and scale to output format
            shift = (x_frac + w_frac) - out_frac
            y[:, out_idx] = round_and_scale(acc_total, shift, total_bits)
            out_idx += 1
            
    return y

def stream_relu(x: np.ndarray) -> np.ndarray:
    """Streaming ReLU activation."""
    return np.maximum(x, 0)

def stream_maxpool1d(x_stream: np.ndarray, kernel_size: int = 2, stride: int = 2) -> np.ndarray:
    """Streaming MaxPool1d layer."""
    channels, length = x_stream.shape
    out_len = (length - kernel_size) // stride + 1
    y = np.zeros((channels, out_len), dtype=np.int64)
    
    for t in range(out_len):
        t0 = t * stride
        for c in range(channels):
            # In hardware, compare elements in the window
            val = x_stream[c, t0]
            for k in range(1, kernel_size):
                if x_stream[c, t0 + k] > val:
                    val = x_stream[c, t0 + k]
            y[c, t] = val
            
    return y

def stream_global_maxpool1d(x_stream: np.ndarray) -> np.ndarray:
    """Streaming Global MaxPool1d layer."""
    channels, length = x_stream.shape
    # Hardware register initialized to lowest possible value
    running_max = np.full((channels, 1), -32768, dtype=np.int64)
    
    for t in range(length):
        for c in range(channels):
            if x_stream[c, t] > running_max[c, 0]:
                running_max[c, 0] = x_stream[c, t]
                
    return running_max

def stream_linear(
    x_stream: np.ndarray,  # (in_features,)
    w: np.ndarray,         # (out_features, in_features)
    b: np.ndarray,         # (out_features,)
    x_frac: int,
    w_frac: int,
    b_frac: int,
    out_frac: int,
    total_bits: int = 16
) -> np.ndarray:
    """Streaming fully connected layer."""
    acc = np.sum(x_stream[None, :] * w, axis=1)
    
    bias_shift = (x_frac + w_frac) - b_frac
    if bias_shift > 0:
        aligned_bias = b << bias_shift
    elif bias_shift < 0:
        aligned_bias = b >> (-bias_shift)
    else:
        aligned_bias = b
        
    acc_total = acc + aligned_bias
    
    shift = (x_frac + w_frac) - out_frac
    return round_and_scale(acc_total, shift, total_bits)

class ShapedECG1DCNN:
    """Hardware-shaped streaming inference model wrapper."""
    def __init__(self, weights_path: str, w_frac: int = 14, act_frac: int = 8):
        self.w_frac = w_frac
        self.act_frac = act_frac
        self.weights = {}
        self.load_weights(weights_path)
        
    def load_weights(self, weights_path: str):
        if weights_path.endswith('.npz'):
            data = np.load(weights_path)
            for k in data.files:
                clean_key = k.replace('.', '_')
                self.weights[clean_key] = to_fixed(data[k], frac_bits=self.w_frac, total_bits=16)
        else:
            manifest_path = os.path.join(weights_path, "weights_manifest.json")
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)
            for k, info in manifest.items():
                clean_key = k.replace('.', '_')
                npy_file = os.path.join(weights_path, f"{info['export_key']}.npy")
                float_w = np.load(npy_file)
                self.weights[clean_key] = to_fixed(float_w, frac_bits=self.w_frac, total_bits=16)

    def forward_sample(self, x_float: np.ndarray) -> Tuple[np.ndarray, Dict[str, np.ndarray]]:
        """Processes a single sample (1, 187) sequentially in streaming fashion."""
        # x_float: (187,)
        x_fixed = to_fixed(x_float, frac_bits=self.act_frac, total_bits=16) # (187,)
        x_stream = x_fixed[None, :] # shape (1, 187) - 1 channel, 187 length
        
        acts = {"input": x_stream}
        
        w = self.weights
        af = self.act_frac
        wf = self.w_frac
        
        # Conv Block 1
        x = stream_conv1d(x_stream, w["conv1_weight"], w["conv1_bias"], af, wf, wf, af); acts["conv1"] = x
        x = stream_relu(x); acts["relu1"] = x
        
        x = stream_conv1d(x, w["conv2_weight"], w["conv2_bias"], af, wf, wf, af); acts["conv2"] = x
        x = stream_relu(x); acts["relu2"] = x
        
        x = stream_maxpool1d(x, kernel_size=2, stride=2); acts["pool1"] = x
        
        # Conv Block 2
        x = stream_conv1d(x, w["conv3_weight"], w["conv3_bias"], af, wf, wf, af); acts["conv3"] = x
        x = stream_relu(x); acts["relu3"] = x
        
        x = stream_conv1d(x, w["conv4_weight"], w["conv4_bias"], af, wf, wf, af); acts["conv4"] = x
        x = stream_relu(x); acts["relu4"] = x
        
        x = stream_maxpool1d(x, kernel_size=2, stride=2); acts["pool2"] = x
        
        # Conv Block 3
        x = stream_conv1d(x, w["conv5_weight"], w["conv5_bias"], af, wf, wf, af); acts["conv5"] = x
        x = stream_relu(x); acts["relu5"] = x
        
        x = stream_conv1d(x, w["conv6_weight"], w["conv6_bias"], af, wf, wf, af); acts["conv6"] = x
        x = stream_relu(x); acts["relu6"] = x
        
        x = stream_global_maxpool1d(x); acts["global_max_pool"] = x
        
        # Flatten: (256, 1) -> (256,)
        x = x.squeeze(1); acts["flatten"] = x
        
        # Classifier
        x = stream_linear(x, w["fc1_weight"], w["fc1_bias"], af, wf, wf, af); acts["fc1"] = x
        x = stream_relu(x); acts["relu7"] = x
        
        x = stream_linear(x, w["fc2_weight"], w["fc2_bias"], af, wf, wf, af); acts["fc2"] = x
        x = stream_relu(x); acts["relu8"] = x
        
        logits = stream_linear(x, w["fc3_weight"], w["fc3_bias"], af, wf, wf, af); acts["logits"] = logits
        
        acts_float = {k: to_float(v, self.act_frac) for k, v in acts.items()}
        logits_float = to_float(logits, self.act_frac)
        
        return logits_float, acts_float

def main():
    print("=== Running Hardware-Shaped Streaming Model Validation ===")
    
    # Initialize both models
    weights_path = "models/float/weights_float32"
    from models.fixed.model_fixed import FixedECG1DCNN
    
    fixed_model = FixedECG1DCNN(weights_path)
    shaped_model = ShapedECG1DCNN(weights_path)
    
    # Load golden samples
    inputs = np.load("datasets/golden_float/golden_inputs_x_float32.npy")
    print(f"Loaded {len(inputs)} samples for bit-exact comparison.")
    
    # Run vectorized fixed model on all samples
    _, acts_fixed = fixed_model.forward_with_activations(inputs)
    
    # Run shaped model sample-by-sample and compare
    mismatch_counts = {}
    
    print("Comparing activations layer-by-layer for all samples...")
    for i in range(len(inputs)):
        # Run shaped model on single sample
        logits_s, acts_s = shaped_model.forward_sample(inputs[i])
        
        # Compare each layer's activations
        for layer in acts_s.keys():
            # Get corresponding activation from vectorized model for sample i
            v_act = acts_fixed[layer][i] # shape: (channels, len) or similar
            s_act = acts_s[layer]
            
            # Squeeze both to avoid shape mismatches from singleton dimensions
            v_act_sq = np.squeeze(v_act)
            s_act_sq = np.squeeze(s_act)
            
            # Check bit-exact match
            diff = np.abs(v_act_sq - s_act_sq)
            max_diff = np.max(diff)
            
            if max_diff > 0:
                mismatch_counts[layer] = mismatch_counts.get(layer, 0) + 1
                if mismatch_counts[layer] <= 3:
                    print(f"Mismatch in {layer} for sample {i}: Max Diff = {max_diff}")
                    
    print("\nSummary of bit-exact mismatch count across 128 samples:")
    if not mismatch_counts:
        print("100% BIT-EXACT MATCH! The hardware-shaped loops and buffers perfectly match the mathematical reference.")
    else:
        for layer, cnt in mismatch_counts.items():
            print(f"Layer {layer:20s}: {cnt} / {len(inputs)} mismatches")
            
if __name__ == "__main__":
    main()

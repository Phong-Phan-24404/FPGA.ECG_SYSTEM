#!/usr/bin/env python3
"""Bit-true fixed-point 1D CNN inference model.

Loads FP32 weights, quantizes them to Q2.14, and executes inference in Q8.8
fixed-point arithmetic to verify classification accuracy on ECG signals.
"""

import argparse
import os
import json
import numpy as np
from typing import Dict, Tuple

from models.common.fixed_ops import (
    to_fixed,
    to_float,
    fixed_conv1d,
    fixed_relu,
    fixed_maxpool1d,
    fixed_global_maxpool1d,
    fixed_linear
)

class FixedECG1DCNN:
    """Fixed-point ECG 1D CNN model with Q2.14 weights and Q8.8 activations."""
    
    def __init__(self, weights_path: str, w_frac: int = 14, act_frac: int = 8):
        self.w_frac = w_frac
        self.act_frac = act_frac
        self.weights = {}
        self.load_and_quantize_weights(weights_path)
        
    def load_and_quantize_weights(self, weights_path: str):
        """Loads float32 weights from .npz or files and quantizes to fixed-point."""
        if not os.path.exists(weights_path):
            raise FileNotFoundError(f"Weights file not found at {weights_path}")
            
        if weights_path.endswith('.npz'):
            data = np.load(weights_path)
            for k in data.files:
                # Map keys if needed (e.g. replacing dots with underscores)
                clean_key = k.replace('.', '_')
                self.weights[clean_key] = to_fixed(data[k], frac_bits=self.w_frac, total_bits=16)
        else:
            # Load from directory of .npy files
            manifest_path = os.path.join(weights_path, "weights_manifest.json")
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)
            for k, info in manifest.items():
                clean_key = k.replace('.', '_')
                npy_file = os.path.join(weights_path, f"{info['export_key']}.npy")
                float_w = np.load(npy_file)
                self.weights[clean_key] = to_fixed(float_w, frac_bits=self.w_frac, total_bits=16)

    def forward_with_activations(self, x_float: np.ndarray) -> Tuple[np.ndarray, Dict[str, np.ndarray]]:
        """Runs fixed-point forward pass and returns float representation of activations."""
        # Ensure channels-first shape (batch, 1, 187)
        if x_float.ndim == 2:
            x_float = x_float[:, None, :]
            
        # 1. Input quantization to Q8.8
        x_fixed = to_fixed(x_float, frac_bits=self.act_frac, total_bits=16)
        
        acts = {"input": x_fixed}
        
        # Helper variables for layer configs
        w = self.weights
        af = self.act_frac
        wf = self.w_frac
        
        # Conv Block 1
        x = fixed_conv1d(x_fixed, w["conv1_weight"], w["conv1_bias"], af, wf, wf, af); acts["conv1"] = x
        x = fixed_relu(x); acts["relu1"] = x
        
        x = fixed_conv1d(x, w["conv2_weight"], w["conv2_bias"], af, wf, wf, af); acts["conv2"] = x
        x = fixed_relu(x); acts["relu2"] = x
        
        x = fixed_maxpool1d(x, kernel_size=2, stride=2); acts["pool1"] = x
        
        # Conv Block 2
        x = fixed_conv1d(x, w["conv3_weight"], w["conv3_bias"], af, wf, wf, af); acts["conv3"] = x
        x = fixed_relu(x); acts["relu3"] = x
        
        x = fixed_conv1d(x, w["conv4_weight"], w["conv4_bias"], af, wf, wf, af); acts["conv4"] = x
        x = fixed_relu(x); acts["relu4"] = x
        
        x = fixed_maxpool1d(x, kernel_size=2, stride=2); acts["pool2"] = x
        
        # Conv Block 3
        x = fixed_conv1d(x, w["conv5_weight"], w["conv5_bias"], af, wf, wf, af); acts["conv5"] = x
        x = fixed_relu(x); acts["relu5"] = x
        
        x = fixed_conv1d(x, w["conv6_weight"], w["conv6_bias"], af, wf, wf, af); acts["conv6"] = x
        x = fixed_relu(x); acts["relu6"] = x
        
        x = fixed_global_maxpool1d(x); acts["global_max_pool"] = x
        
        # Flatten: (batch, 256, 1) -> (batch, 256)
        x = x.squeeze(2); acts["flatten"] = x
        
        # Classifier
        x = fixed_linear(x, w["fc1_weight"], w["fc1_bias"], af, wf, wf, af); acts["fc1"] = x
        x = fixed_relu(x); acts["relu7"] = x
        
        x = fixed_linear(x, w["fc2_weight"], w["fc2_bias"], af, wf, wf, af); acts["fc2"] = x
        x = fixed_relu(x); acts["relu8"] = x
        
        logits = fixed_linear(x, w["fc3_weight"], w["fc3_bias"], af, wf, wf, af); acts["logits"] = logits
        
        # Convert all activation integers back to floats for comparison
        acts_float = {k: to_float(v, self.act_frac) for k, v in acts.items()}
        logits_float = to_float(logits, self.act_frac)
        
        return logits_float, acts_float

    def predict(self, x_float: np.ndarray, batch_size: int = 512) -> np.ndarray:
        """Runs fixed-point inference in batches and returns predicted class indices."""
        num_samples = len(x_float)
        preds = []
        for i in range(0, num_samples, batch_size):
            x_batch = x_float[i:i+batch_size]
            logits_float, _ = self.forward_with_activations(x_batch)
            preds.append(np.argmax(logits_float, axis=1))
        return np.concatenate(preds, axis=0)

def run_smoke_test(model: FixedECG1DCNN):
    print("=== Running Fixed-Point Smoke Test on Golden Sample ===")
    
    # Load golden data
    inputs = np.load("datasets/golden_float/golden_inputs_x_float32.npy")
    labels = np.load("datasets/golden_float/golden_labels_int64.npy")
    golden_logits = np.load("datasets/golden_float/golden_logits_float32.npy")
    golden_acts_data = np.load("datasets/golden_float/golden_activations_float32.npz")
    
    print(f"Loaded {len(inputs)} golden samples.")
    
    # Run fixed point forward pass
    logits_fixed, acts_fixed = model.forward_with_activations(inputs)
    
    # Compute error metrics on logits
    mismatch_cnt = 0
    predictions = np.argmax(logits_fixed, axis=1)
    golden_predictions = np.argmax(golden_logits, axis=1)
    
    for i in range(len(inputs)):
        if predictions[i] != golden_predictions[i]:
            mismatch_cnt += 1
            
    print(f"Logits prediction mismatch: {mismatch_cnt} / {len(inputs)} samples.")
    
    # Calculate SNR and MSE between golden float logits and fixed float logits
    mse_logits = np.mean((golden_logits - logits_fixed) ** 2)
    signal_power = np.mean(golden_logits ** 2)
    snr_logits = 10 * np.log10(signal_power / mse_logits) if mse_logits > 0 else float('inf')
    
    print(f"Logits Mean Squared Error (MSE): {mse_logits:e}")
    print(f"Logits Signal-to-Noise Ratio (SNR): {snr_logits:.2f} dB")
    
    # Print layer-wise statistics
    print("\nLayer-wise Mismatch against Golden Float Activations:")
    print(f"{'Layer Name':25s} | {'Shape':15s} | {'MSE':12s} | {'SNR (dB)':10s}")
    print("-" * 70)
    for layer in acts_fixed.keys():
        if layer == "input":
            continue
        # Check if layer in golden activations (some are named differently,bn is skipped)
        g_layer = layer
        if layer == "relu1": g_layer = "relu1"
        elif layer == "relu2": g_layer = "relu2"
        elif layer == "pool1": g_layer = "pool1"
        elif layer == "relu3": g_layer = "relu3"
        elif layer == "relu4": g_layer = "relu4"
        elif layer == "pool2": g_layer = "pool2"
        elif layer == "relu5": g_layer = "relu5"
        elif layer == "relu6": g_layer = "relu6"
        elif layer == "global_max_pool": g_layer = "global_max_pool"
        elif layer == "flatten": g_layer = "flatten"
        elif layer == "fc1": g_layer = "fc1"
        elif layer == "relu7": g_layer = "relu7"
        elif layer == "fc2": g_layer = "fc2"
        elif layer == "relu8": g_layer = "relu8"
        elif layer == "logits": g_layer = "logits"
        else:
            continue
            
        if g_layer in golden_acts_data:
            g_act = golden_acts_data[g_layer]
            if g_act.shape != acts_fixed[layer].shape:
                # Might have extra singleton dimensions, squeeze them
                g_act = np.squeeze(g_act)
                f_act = np.squeeze(acts_fixed[layer])
            else:
                f_act = acts_fixed[layer]
                
            mse = np.mean((g_act - f_act) ** 2)
            sig_power = np.mean(g_act ** 2)
            snr = 10 * np.log10(sig_power / mse) if mse > 0 else float('inf')
            print(f"{layer:25s} | {str(f_act.shape):15s} | {mse:12.6e} | {snr:10.2f}")
            
    success = mismatch_cnt == 0 and snr_logits > 25.0
    print(f"\nSmoke Test Passed: {success}")
    return success

def run_test_set_evaluation(model: FixedECG1DCNN, dataset_csv: str):
    import pandas as pd
    print(f"\n=== Evaluating on Test Set: {dataset_csv} ===")
    if not os.path.exists(dataset_csv):
        print(f"Error: Dataset {dataset_csv} not found.")
        return
        
    df = pd.read_csv(dataset_csv, header=None)
    labels = df.iloc[:, 187].values.astype(int)
    features = df.iloc[:, :187].values.astype(np.float32)
    
    # Run fixed point model
    print(f"Running inference on {len(features)} samples...")
    preds = model.predict(features)
    
    # Calculate accuracy
    acc = np.mean(preds == labels)
    print(f"Accuracy: {acc:.6f} ({np.sum(preds == labels)} / {len(labels)})")
    
    # Write summary
    metrics = {
        "fixed_accuracy": float(acc),
        "samples": int(len(labels)),
        "w_frac": model.w_frac,
        "act_frac": model.act_frac
    }
    with open("datasets/golden_fixed/fixed_metrics.json", "w") as f:
        json.dump(metrics, f, indent=2)
    print("Metrics written to datasets/golden_fixed/fixed_metrics.json")

def main():
    parser = argparse.ArgumentParser(description="Fixed point 1D CNN ECG validation")
    parser.add_argument("--weights", type=str, default="models/float/weights_float32",
                        help="Path to float weights directory or npz")
    parser.add_argument("--smoke", action="store_true", help="Run smoke test against golden samples")
    parser.add_argument("--test-set", type=str, default="kaggle/input/mitbih_test.csv",
                        help="Path to full test dataset CSV")
    args = parser.parse_args()
    
    # Initialize model
    model = FixedECG1DCNN(weights_path=args.weights, w_frac=14, act_frac=8)
    
    if args.smoke:
        run_smoke_test(model)
    else:
        # Default is to run smoke test, then optionally the full test set
        smoke_ok = run_smoke_test(model)
        if smoke_ok and os.path.exists(args.test_set):
            run_test_set_evaluation(model, args.test_set)

if __name__ == "__main__":
    main()

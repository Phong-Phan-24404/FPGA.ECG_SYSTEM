#!/usr/bin/env python3
"""Script to analyze dynamic ranges of weights and activations to select fixed-point Q-formats."""

import json
import os
import numpy as np

def analyze_weights(weights_manifest_path, weights_dir):
    print("=== Weight Range Analysis ===")
    with open(weights_manifest_path, 'r') as f:
        manifest = json.load(f)
    
    weight_ranges = {}
    for key, info in manifest.items():
        npy_file = os.path.join(weights_dir, f"{info['export_key']}.npy")
        if not os.path.exists(npy_file):
            print(f"Error: Weight file {npy_file} not found.")
            continue
        weights = np.load(npy_file)
        min_val, max_val = float(weights.min()), float(weights.max())
        mean_val, std_val = float(weights.mean()), float(weights.std())
        
        # Determine minimum bits needed for integer part (excluding sign bit)
        # We need range: [-max_abs, max_abs]
        max_abs = max(abs(min_val), abs(max_val))
        int_bits = int(np.ceil(np.log2(max_abs))) if max_abs > 0 else 0
        int_bits = max(0, int_bits) # at least 0 integer bits
        
        # Proposed format with 16-bit word size:
        # Total bits = 16. Sign bit = 1.
        # Fractional bits = 16 - 1 - int_bits
        frac_bits = 15 - int_bits
        
        weight_ranges[key] = {
            "shape": list(weights.shape),
            "min": min_val,
            "max": max_val,
            "mean": mean_val,
            "std": std_val,
            "suggested_int_bits": int_bits,
            "suggested_frac_bits": frac_bits,
            "suggested_q_format": f"Q{int_bits+1}.{frac_bits}"
        }
        print(f"Layer {key:15s} | Shape: {str(weights.shape):15s} | Range: [{min_val:8.4f}, {max_val:8.4f}] | Suggested: {weight_ranges[key]['suggested_q_format']}")
        
    return weight_ranges

def analyze_activations(activations_npz_path):
    print("\n=== Activation Range Analysis ===")
    if not os.path.exists(activations_npz_path):
        print(f"Error: Activation NPZ file {activations_npz_path} not found.")
        return {}
        
    data = np.load(activations_npz_path)
    activation_ranges = {}
    for key in data.files:
        act = data[key]
        min_val, max_val = float(act.min()), float(act.max())
        mean_val, std_val = float(act.mean()), float(act.std())
        
        max_abs = max(abs(min_val), abs(max_val))
        int_bits = int(np.ceil(np.log2(max_abs))) if max_abs > 0 else 0
        int_bits = max(0, int_bits)
        frac_bits = 15 - int_bits # 16-bit total
        
        # For unsigned ReLU activations, sign bit might not be needed in HW, but let's keep it signed for safety in software reference model.
        activation_ranges[key] = {
            "shape": list(act.shape),
            "min": min_val,
            "max": max_val,
            "mean": mean_val,
            "std": std_val,
            "suggested_int_bits": int_bits,
            "suggested_frac_bits": frac_bits,
            "suggested_q_format": f"Q{int_bits+1}.{frac_bits}"
        }
        print(f"Layer {key:20s} | Shape: {str(act.shape):15s} | Range: [{min_val:8.4f}, {max_val:8.4f}] | Suggested: {activation_ranges[key]['suggested_q_format']}")
        
    return activation_ranges

def main():
    weights_manifest = "models/float/weights_float32/weights_manifest.json"
    weights_dir = "models/float/weights_float32"
    activations_npz = "datasets/golden_float/golden_activations_float32.npz"
    
    weight_ranges = analyze_weights(weights_manifest, weights_dir)
    act_ranges = analyze_activations(activations_npz)
    
    # Save results to a json file
    analysis_results = {
        "weights": weight_ranges,
        "activations": act_ranges
    }
    
    output_path = "datasets/golden_float/quantization_analysis_results.json"
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(analysis_results, f, indent=2)
    print(f"\nAnalysis results saved to {output_path}")

if __name__ == "__main__":
    main()

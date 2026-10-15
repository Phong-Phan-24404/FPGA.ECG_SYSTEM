# Golden reference models

| Folder | Purpose |
|---|---|
| `01_FP32_reference/` | Trained floating-point CNN and weights |
| `02_fixed_point_reference/` | Quantized fixed-point reference |
| `03_hardware_aligned_reference/` | Hardware-shaped layer behavior |
| `04_quantization_and_data_tools/` | Fixed-point utilities and ECG vector generation |

**RTL Design:** Arithmetic and quantization contract. **Verification:** Golden output comparison. **FPGA:** Convert weights to hardware-compatible formats.

The original MIT-BIH source CSV is not included; some data-generation scripts require an external CSV.

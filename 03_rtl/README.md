# CNN accelerator RTL and packaged IP

| Folder | Purpose |
|---|---|
| [`01_CNN_accelerator_IP/`](01_CNN_accelerator_IP/) | IP-XACT `component.xml`, SystemVerilog `src/`, Vivado `xgui/` |
| [`02_weight_ROM_reference/`](02_weight_ROM_reference/) | Scalar and banked golden weight ROMs |
| [`03_Vivado_IP_build_scripts/`](03_Vivado_IP_build_scripts/) | Synthesis pre-hook for ROM staging |

**RTL Design:** Streaming convolution, FC, AXI and quantization. **Verification:** Golden weight mapping is checked independently. **FPGA:** Vivado custom IP package with unchanged internal `src/`/`xgui/` metadata references.

RTL `$readmemh` still uses `datasets/golden_fixed/...` inside a **staged runtime workspace**; do not change those literals to repository paths.

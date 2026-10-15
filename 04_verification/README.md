# Hardware design verification

| Folder | Purpose |
|---|---|
| [`01_RTL_unit_testbenches/`](01_RTL_unit_testbenches/) | Unit/subsystem tests; `common/` contains reusable test harnesses |
| [`02_PS_PL_integration_testbenches/`](02_PS_PL_integration_testbenches/) | Zynq PS–PL and DMA/IRQ testbenches |
| [`03_automated_regression/`](03_automated_regression/) | Fail-closed simulation runner and ROM banking checker |
| [`04_post_synthesis_verification/`](04_post_synthesis_verification/) | Vivado OOC/netlist verification flow |
| [`05_golden_test_vectors/`](05_golden_test_vectors/) | Reference ECG inputs, labels and layer outputs |
| [`06_verification_evidence/`](06_verification_evidence/) | Selected module/OOC utilization reports |

**RTL Design:** Datapath/AXI behavior. **Verification:** Bit-exact self-checking regression; **26/26 historical passes**, not rerun. **FPGA:** Post-synthesis and PS–PL integration tests.

```bash
python3 04_verification/03_automated_regression/run_regression.py --suite smoke --dry-run
python3 04_verification/03_automated_regression/verify_weights.py
```

Golden ROM/vector data are staged in `.regression_work/runtime/datasets/golden_fixed/` so Verilog `$readmemh` retains its verified relative paths.

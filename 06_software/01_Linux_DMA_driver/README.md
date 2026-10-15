# Linux DMA driver and standalone board test

| File/folder | Purpose |
|---|---|
| `pl_dmabuf.c`, `Makefile` | Kernel module for DMA buffer |
| `cnn_run.c`, `run_all.sh` | AXI/DMA host test |
| `01_golden_board_test_vectors/` | Known ECG samples and expected logits |

**RTL Design:** Memory-mapped control path. **Verification:** Input/output comparison. **FPGA:** Standalone KV260 bring-up.

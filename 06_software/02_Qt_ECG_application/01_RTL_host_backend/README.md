# Qt application's RTL host backend

| File/folder | Role |
|---|---|
| `cnn_run.c`, `pl_dmabuf.c`, `Makefile` | Standalone DMA host/kernel build |
| `01_golden_board_test_vectors/` | Board test samples and expected logits |

**RTL Design:** AXI interface. **Verification:** Sample-by-sample host comparison. **FPGA:** Kernel DMA and board test integration.

# Linux/Qt host software

| Folder | Purpose |
|---|---|
| [`01_Linux_DMA_driver/`](01_Linux_DMA_driver/) | Standalone DMA kernel module and board-side inference test |
| [`02_Qt_ECG_application/`](02_Qt_ECG_application/) | Qt ECG monitoring UI; RTL/CPU/DPU backends |

**RTL Design:** Exercise AXI/DMA interface. **Verification:** Compare host-PL output with golden vectors. **FPGA:** End-to-end KV260 Linux app integration.

Independent host copies remain separate because they have distinct build/deployment contexts.

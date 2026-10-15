# KV260 deployment artifacts

| File | Role |
|---|---|
| `system_wrapper.bit` | Vivado-generated system bitstream |
| `kv260-cnn.bit.bin` + `kv260-cnn.dtbo` + `shell.json` | KV260 Linux overlay set |

**RTL Design:** Deploy packaged CNN hardware. **Verification:** Historical 25/25 bit-exact on-board logits. **FPGA:** Historical 21,892-beat evaluation: 98.16% accuracy, 0.8902 macro-F1 and 1.041 ms mean latency.

Do not assume all files are from the same build/release without further provenance verification.

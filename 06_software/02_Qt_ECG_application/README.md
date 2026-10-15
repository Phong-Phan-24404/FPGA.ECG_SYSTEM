# Qt ECG monitoring application

| File/folder | Purpose |
|---|---|
| `src/`, `CMakeLists.txt` | Qt/C++ ECG UI and backend selection |
| `01_RTL_host_backend/` | FPGA DMA host implementation and test vectors |
| `02_build_and_test_scripts/` | Host checks, x86/ARM builds and deployment scripts |
| `python/`, `models/`, `data/` | Runtime CPU/DPU backends and ECG samples |

**RTL Design:** AXI-host interface. **Verification:** Known-vector hardware tests. **FPGA:** Qt interface and CPU/RTL/DPU backend integration.

Run from this directory: `bash 02_build_and_test_scripts/check_source.sh`.

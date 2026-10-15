# KV260 PS–PL integration and deployment

| Folder | Purpose |
|---|---|
| [`01_PS_PL_block_design/`](01_PS_PL_block_design/) | Zynq PS + AXI DMA/interconnect + CNN IP; `01_Vivado_design_export/` contains the `.bd` and generated IP hierarchy |
| [`02_synthesis_implementation_results/`](02_synthesis_implementation_results/) | Synthesized and routed resource/timing reports for released v3 |
| [`03_timing_closure_study/`](03_timing_closure_study/) | **Historical v1.6 serial design** clock analysis; not directly comparable to v3 |
| [`04_KV260_deployment/`](04_KV260_deployment/) | Bitstreams, device tree overlay and shell metadata |

**RTL Design:** Custom CNN AXI integration. **Verification:** System benches in [`04_verification`](../04_verification/02_PS_PL_integration_testbenches/). **FPGA:** Released 100 MHz implementation: **+1.733 ns WNS** and **90.28% BRAM utilization** (historical).

The Vivado-generated `ip/`, `ui/` and `system*.xci` names are preserved to avoid changing the BD/IP internal object identifiers. Regeneration in Vivado has not been checked here.

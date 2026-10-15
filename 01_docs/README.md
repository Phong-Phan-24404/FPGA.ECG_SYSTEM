# System architecture and file provenance

![Layered architecture](01_system_architecture/system_layered_architecture.png)

| Figure or artifact | Focus |
|---|---|
| [PS–PL dataflow](01_system_architecture/ps_pl_dataflow.png) | CPU, DMA, AXI and CNN datapath |
| [Vivado block design diagram](01_system_architecture/system_bd_single_clock.png) | Zynq PS–PL integration at 100 MHz |
| [KV260 demo setup](01_system_architecture/demo_setup.jpg) | On-board setup |
| [File mapping](path_mapping.csv) | Historical paths → current paths with checksums |

**RTL Design:** CNN microarchitecture. **Verification:** System interfaces. **FPGA:** PS–PL integration and board deployment.

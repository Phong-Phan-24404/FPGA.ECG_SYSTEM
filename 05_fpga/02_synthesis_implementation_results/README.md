# Released v3 synthesis and implementation results

| Report group | Stage |
|---|---|
| [`01_synthesis/`](01_synthesis/) | Vivado synthesis estimates |
| [`02_post_route_implementation/`](02_post_route_implementation/) | Routed timing, DRC and area evidence |

| Post-route metric | Recorded value |
|---|---:|
| PL clock / WNS / WHS | 100 MHz / **+1.733 ns** / **+0.012 ns** |
| LUT / FF | 23,987 / 39,800 |
| BRAM / DSP | 130 / 144 (**90.28%**) · 169 / 1,248 (**13.54%**) |

**RTL Design:** Investigate conv6 DSP input timing. **Verification:** Tool reports complement functional tests. **FPGA:** Prefer routed reports to synthesis estimates.

# Synthesizable CNN accelerator IP

| Path | Content |
|---|---|
| `src/` | Synthesizable SystemVerilog and packaged ROM images |
| `xgui/` | Vivado IP customization metadata |
| `component.xml` | IP-XACT package manifest |

**RTL Design:** Streamed convolution, FC and fixed-point operations. **Design Verification:** Exercised by `04_verification`. **FPGA:** Packaged for Vivado PS–PL block design integration.

`src/` and `xgui/` retain standard names referenced inside `component.xml`.

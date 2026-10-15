# Zynq PS–PL block design

The design connects **Zynq UltraScale+ PS**, AXI interconnect/DMA and the custom CNN accelerator IP.

| Path | Content |
|---|---|
| `01_Vivado_design_export/system.bd` | Vivado block-design source |
| `01_Vivado_design_export/ip/` | Generated/configured IP descriptions (`.xci`) |
| `01_Vivado_design_export/ui/` | Vivado UI metadata |

**RTL Design:** CNN-to-AXI integration. **Design Verification:** System testbenches are in `04_verification`. **FPGA:** PS–PL architecture and IP configuration.

Vendor-generated `ip/`, `ui/` and `system_*` identifiers are intentionally **not renamed**.

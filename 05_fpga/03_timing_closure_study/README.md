# Historical clock study (v1.6 serial CNN)

**Do not compare these timing runs directly with released v3 parallel CNN.**

| Folder | Recorded WNS at 100 MHz |
|---|---:|
| [`01_baseline_100MHz/`](01_baseline_100MHz/) | +0.980 ns |
| [`02_clock_optimized_100MHz/`](02_clock_optimized_100MHz/) | +0.623 ns |

`fix_clk_wiz_primary_clock.tcl` is retained as the clock-constraint correction script.

**RTL Design:** Historical serial datapath. **Verification:** Clock definition integrity. **FPGA:** Constraint and timing analysis.

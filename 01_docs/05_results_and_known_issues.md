# Results and known issues

Every measured number this project claims, the file that backs it, and every caveat worth
knowing before quoting one.

**Read §3 before putting any figure in a slide.**

---

## 1. Measured results

### Implementation — released `CNN_wrapper` v3.0, 100 MHz, `xck26-sfvc784-2LV-c`

| | Value | Evidence |
| :--- | ---: | :--- |
| WNS / TNS | **+1.733 ns** / 0.000 ns | [`00_headline.txt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/00_headline.txt) |
| WHS / THS | **+0.012 ns** / 0.000 ns | same |
| Timed endpoints | 119 186 setup and hold | same |
| Routing | 66 218 / 66 218 nets, 0 errors | [`route_status.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/route_status.rpt) |
| DRC | 526 checks, **0 errors** | [`drc.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/drc.rpt) |
| CDC | empty report | [`cdc.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/cdc.rpt) |
| LUT / FF | 23 987 (20.48 %) / 39 800 (16.99 %) | [`utilization.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/utilization.rpt) |
| CLB occupancy | 7 105 (48.53 %) | same |
| **BRAM** | **130 / 144 (90.28 %)** | same |
| DSP48E2 | 169 (13.54 %) | same |
| Power / Tj | 3.199 W / 32.4 °C | [`power.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/power.rpt) |
| Bitstream | 7 797 810 bytes | [`system_wrapper.bit`](../05_fpga/04_KV260_deployment/system_wrapper.bit) |

### Verification

| | Value | Evidence |
| :--- | ---: | :--- |
| RTL regression | 26 benches, 26 PASS, 0 FAIL | [`RESULTS.md`](../04_verification/03_automated_regression/RESULTS.md) |
| Weight-banking re-derivation | 224 256 weights, exact permutation | same |
| Gate-level, pre-fix | 37 PASS / 12 FAIL, reproduced silicon bit for bit | [`sim_postsynth_before_fix.log`](../04_verification/06_verification_evidence/02_post_synthesis_utilization/sim_postsynth_before_fix.log) |
| Gate-level, post-fix | 39 PASS / 0 FAIL | [`sim_postsynth_after_fix.log`](../04_verification/06_verification_evidence/02_post_synthesis_utilization/sim_postsynth_after_fix.log) |
| Per-layer netlist sweep | conv1 1678/2928 FAIL, all other layers 0 | [`01_convolution_layer_synthesis/`](../04_verification/06_verification_evidence/01_convolution_layer_synthesis/) |
| Saturation events, full test set | **0 of 687 343 124** | §5 below |

### Silicon — KV260, firmware hash-matched to this repository

| | Value | Evidence |
| :--- | ---: | :--- |
| Reference beats bit-exact | **5 / 5** (25 / 25 logits) | [`board_golden_check_v3.txt`](../04_verification/06_verification_evidence/03_board_silicon_results/board_golden_check_v3.txt) |
| Accuracy, 21 892 beats | **98.16 %** | [`board_fullset_v3.txt`](../04_verification/06_verification_evidence/03_board_silicon_results/board_fullset_v3.txt) |
| **Macro F1** | **0.8902** | same |
| Weighted F1 | 0.9805 | same |
| Latency | 1.041 ms/beat (~964 beats/s) | same |
| Full test set run time | 22.9 s | same |
| Determinism between runs | identical | [`board_run_all_v3.txt`](../04_verification/06_verification_evidence/03_board_silicon_results/board_run_all_v3.txt) |

Per-class F1: N 0.9906 · S 0.7715 · V 0.9536 · F 0.7482 · Q 0.9872.

### Performance

| Measure | Value |
| :--- | ---: |
| Frame latency, RTL sim @100 MHz | 103 210 cycles = 1.032 ms |
| Frame latency, block-design sim | ~104 000 cycles, S2MM IRQ at 1.042 ms |
| Frame latency, measured on KV260 | **1.037 – 1.041 ms** |
| Backpressure sensitivity | 103 208 / 103 210 / 103 250 cycles at 0 / 30 / 80 % output stall |
| Speed-up over the Phase-1 serial design | 4.23× |

Simulation and silicon agree to within about 1 %, which is itself a result: the cycle model is
real.

## 2. Artifact provenance is closed

| Link | Check | Result |
| :--- | :--- | :--- |
| Published boot artifact → what ran on the board | `kv260-cnn.bit.bin` | md5 `05fbb65b…f6b8` — **identical** |
| Published overlay → what ran on the board | `kv260-cnn.dtbo` | md5 `2eb6c60b…c7fe` — **identical** |

Both board-side hashes are recorded inside
[`board_golden_check_v3.txt`](../04_verification/06_verification_evidence/03_board_silicon_results/board_golden_check_v3.txt).
The firmware in this repository is provably the firmware that produced the silicon numbers above.

Every file carried into this repository also has a before/after SHA-256 in
[`path_mapping.csv`](path_mapping.csv).

## 3. Reading traps — numbers that look comparable and are not

### 3.1 Quote macro-F1, not accuracy

Class N is **82.76 %** of the test set, so a classifier answering "N" to everything already
scores above 82 % accuracy. The worst confusion is **32.7 % of true S beats predicted as N**;
per-class recall is S **0.6529** and F **0.6420**. This is model behaviour — the fixed-point
reference reproduces it exactly — not a hardware fault. Any clinical framing has to start here.

### 3.2 The timing-closure study is a different design

[`../05_fpga/03_timing_closure_study/`](../05_fpga/03_timing_closure_study/) was built against
`CNN_wrapper` **v1.6**, the serial datapath: **46 721 LUTs, 11 DSPs**. The released build is
v3.0 parallel: 23 987 LUTs, 169 DSPs. Its WNS, resources and Fmax are **not comparable** to §1.
Only the constraint fix carries forward.

| Build | IP | Datapath | WNS | WHS | LUT | DSP |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: |
| baseline | v1.6 | serial | +0.980 ns | +0.012 ns | 46 721 | 11 |
| clocking clean-up | v1.6 | serial | +0.623 ns | +0.010 ns | 46 634 | 11 |
| **released** | **v3.0** | **parallel** | **+1.733 ns** | **+0.012 ns** | **23 987** | **169** |

### 3.3 Out-of-context IP timing is not system timing

`+1.705 ns` appears in the development-phase reports. That is **out-of-context, the IP alone**,
with `HD.CLK_SRC` unset, so clock delay and skew are not modelled. It is not comparable to a
system-level post-route WNS.

### 3.4 Pre-fix silicon numbers describe broken hardware

The v2.0 bitstream measured **97.07 % / 0.8677 macro-F1** with 0 of 5 samples bit-exact. Those
numbers are the conv1 SRL defect, not the design. Quote the v3.0 figures.

### 3.5 PL-vs-CPU speed-up needs its baseline stated

The measured ~86× is against a clean NumPy transcription of the float reference running on one
Cortex-A53 core. That board has no OpenBLAS, no MKL, no PyTorch, and three of its four cores
idle. It is a fair *reference* comparison, not a comparison against optimised CPU code — NEON or
multi-threading would close part of the gap.

### 3.6 Energy is an order of magnitude, not a figure

Three power runs gave 11×, 32× and 26×, because the power deltas are only 2–6× the INA260 sensor
noise (0.067 W). The honest claim is "about an order of magnitude". Do not quote a single ratio.

### 3.7 Two weight counts appear in the record

**247 632** is the gate-verified figure — every scalar weight re-derived from the 42 packed bank
files and mutation-proven. **224 256** is the conv4–conv6 subset that
[`verify_weights.py`](../04_verification/03_automated_regression/verify_weights.py) re-derives.
Use 247 632 for "weights in the network", 224 256 for "weights the banking check covers".

### 3.8 Frame latency: 85.8 ms is obsolete

Older material quotes 8 577 463 cycles / 85.8 ms per inference. That is the pre-Phase-2 serial
design. The current figure is **103 210 cycles / 1.03 ms**. Budgeting a simulation run against
85.8 ms makes a healthy run look hung.

## 4. Benign warnings — expected, do not re-investigate

### Implementation DRC: 526 checks, 0 errors

| Rule | Count | Why benign |
| :--- | ---: | :--- |
| `DPIP-2` | 185 | DSP48 input-pipelining advisory. Measured off the critical path; enabling it would shorten paths that already have slack. |
| `DPOP-3` | 169 | PREG output pipelining, same reasoning. |
| `DPOP-4` | 169 | MREG output pipelining, same reasoning. |
| `REQP-1935` | 2 | Inside Xilinx's own AXI DMA FIFO, not in design RTL. |
| `RTSTAT-10` | 1 | SmartConnect reset net with no routable loads. |

### Methodology: 2 advisories

`CLKC-40` (an MMCME4 a PLLE4 could serve) and `CLKC-56` (MMCME4 without a LOC). Both advisory,
both about the clocking wizard, neither affects closure.

### Synthesis: 427 warnings, 0 critical

Almost all are inside Xilinx IP — unconnected PS8 ports, undriven pins tied to 0 in the AXI DMA,
duplicate `X_INTERFACE_MODE` in SmartConnect, `proc_sys_reset` CDC-chain pruning. Two touch
design RTL and both were analysed:

- `[Synth 8-6014] issue_ic_reg removed` — **correct**: at conv1, `IN_CHANNELS = 1`, so the guard
  `issue_ic != IN_CHANNELS-1` never fires and the register is a constant 0.
- `[Synth 8-11357] 3D-RAM runtime advisory on window_buf_reg` — a synthesis **runtime** advisory,
  not a correctness warning. Investigated during the conv1 defect hunt and explicitly rejected as
  the cause.

### Board-side messages at overlay load

A batch of *"memory leak will occur if overlay removed"* warnings, and `zocl: IRQ index 0 not
found` (the device-tree generator makes `zocl` claim all 32 INTC lines while the DMA owns inputs
0 and 1). Neither affects the datapath.

## 5. Open technical issues

### 5.1 Hold margin is 12 ps — a tripwire, not headroom

`WHS +0.012 ns`, `THS 0.000 ns`. Hold is **met** and the build is sound. But the previous build
held `+0.073 ns`, and the margin fell when the conv1 fix added 79 flip-flops and place-and-route
re-seeded. Re-check `WHS` on every build and treat a drop below zero as a stop. **Do not spend
this margin.**

### 5.2 BRAM is the binding resource at 90.28 %

14 tiles of headroom for anything else in the PL. The mapping is not inefficient — conv6 alone
needs 96 tiles for exactly its 3 145 728 weight bits. URAM would free ~96 tiles but **cannot be
used**: this device rejects non-zero URAM initialisation (`[Synth 8-10226]`) and `$readmemh`
silently falls back to BRAM. Tested, not assumed.

### 5.3 The defect class that broke silicon has no automated gate

A single Vivado SRL inference in conv1 made the netlist compute something the RTL does not
describe, and **every RTL test stayed green**. The fix (`shreg_extract = "no"`) is in place, but
nothing asserts that it stays: a future `PAR_OUT` or `K_PAR` change could collapse another array
into the same pattern. A synthesis gate asserting `LUT as Shift Register == 0` inside
`CNN_wrapper` is **proposed and not implemented** — the highest-value outstanding verification
work. Full account: [03_verification_strategy.md](03_verification_strategy.md) §5.

### 5.4 Saturation logic is never reached by real data

Zero saturation events in 687 343 124 requantizations is a good result for the Q-format choice
and a **coverage hole** for the saturation logic itself. Only randomised stress reaches it.

### 5.5 Class S and F recall are weak

See §3.1.

### 5.6 No formal verification, no coverage closure, single seed

See [03_verification_strategy.md](03_verification_strategy.md) §8.

## 6. What this repository does not contain

| Absent | Why | Where to look instead |
| :--- | :--- | :--- |
| Vivado project, `.runs/`, `.cache/`, `.gen/` | regenerated by the scripts; large and machine-specific | [`../05_fpga/02_synthesis_implementation_results/`](../05_fpga/02_synthesis_implementation_results/) holds every report they would produce |
| The exported `.xsa` | derived from the published `.bit` | [`../05_fpga/04_KV260_deployment/`](../05_fpga/04_KV260_deployment/) |
| `scripts_build/` Vivado step scripts | live in the development tree | [04_fpga_implementation.md](04_fpga_implementation.md) §5–§6 documents every command |
| `CNN_wrapper` v1.6 and v2.0 | superseded; v2.0 is kept privately as the regression reference that reproduces the pre-fix divergence | [03_verification_strategy.md](03_verification_strategy.md) §5 |
| Eight Phase-1 testbenches | they drove `conv1d_stream` and `global_maxpool1d_stream`, which v3.0 does not ship | — |
| MIT-BIH dataset | third-party licensing | [`../02_model/04_quantization_and_data_tools/make_samples.py`](../02_model/04_quantization_and_data_tools/make_samples.py) consumes `mitbih_test.csv` |
| DPU build artifacts | separate deployment path | [`../06_software/02_Qt_ECG_application/models/`](../06_software/02_Qt_ECG_application/models/) carries the `.xmodel` the app loads |

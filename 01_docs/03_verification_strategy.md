# Verification strategy

**Audience: design verification.** What is checked, at which level, by what evidence — and what
is *not* checked.

Collateral: [`../04_verification/`](../04_verification/).

---

## 1. The principle this project is built on

> A green suite is worth exactly what it costs to make it go red.

Every gate here has been falsified at least once and then restored. Where that was not done, it
is stated as a gap rather than implied as coverage. Section 6 lists the negative controls;
section 8 lists what is still uncovered.

## 2. The pyramid

| Level | Scope | Result | Evidence |
| :--- | :--- | :--- | :--- |
| Unit | each module against golden vectors in isolation | PASS | [`../04_verification/01_RTL_unit_testbenches/`](../04_verification/01_RTL_unit_testbenches/) |
| Parallel engine | the parallelised conv1–conv6 and fc1–fc2 engines | PASS | `tb_conv1d_parallel_*`, `tb_linear_parallel_*` |
| Multiblock | chained conv → ReLU → pool paths | PASS | `tb_chain_a`, `tb_chain_b` |
| Reset / recovery | mid-frame reset at core and wrapper level | PASS | `tb_ecg_accel_top_reset`, `tb_cnn_wrapper_reset` |
| Inter-layer taps | every layer boundary compared, not just the logits | PASS | `tb_system_top_taps`, census in [`../04_verification/06_verification_evidence/04_inter_layer_tap_census/`](../04_verification/06_verification_evidence/04_inter_layer_tap_census/) |
| System (RTL) | full accelerator + AXI wrapper, 5 golden beats | PASS | `CNN_wrapper_tb`, `tb_system_top_regression` |
| Block design | Zynq VIP + AXI DMA + IP, PS-DDR to PS-DDR | PASS | [`../04_verification/02_PS_PL_integration_testbenches/`](../04_verification/02_PS_PL_integration_testbenches/) |
| **Gate level** | the synthesised netlist, not the RTL | **PASS after fix** | [`../04_verification/04_post_synthesis_verification/`](../04_verification/04_post_synthesis_verification/) |
| **Silicon** | KV260 PL, real DMA, real DDR | **25/25 logits bit-exact** | [`../04_verification/06_verification_evidence/03_board_silicon_results/`](../04_verification/06_verification_evidence/03_board_silicon_results/) |

Measured totals for the published tree are in
[`../04_verification/03_automated_regression/RESULTS.md`](../04_verification/03_automated_regression/RESULTS.md).

The gate-level row is the one worth pausing on. Before the conv1 fix, **every level above it was
green and the silicon was still wrong** (§5).

## 3. What each testbench actually proves

| Testbench | Proves |
| :--- | :--- |
| `tb_math_helper` | the rounding/saturation primitive matches the frozen arithmetic contract |
| `tb_ecg_accel_top_shape_check` | layer dimensions in RTL match `ecg_params_pkg` |
| `tb_ecg_accel_top_smoke` | the full chain accepts a frame and produces five beats |
| `tb_axis_stream_fifo` | the conv6 decoupling FIFO, including reset flush and decoupling |
| `tb_conv1d_parallel_conv1..6` | each conv engine bit-exact against golden, AXI stall-safe |
| `tb_linear_parallel_fc1/fc2`, `tb_linear*` | the linear engines, parallel and serial |
| `tb_maxpool1d`, `tb_relu`, `tb_relu_global_maxpool1d` | pooling, activation, and the fused tail |
| `tb_chain_a/b` | chained layer boundaries, where handshake bugs live |
| `tb_ecg_accel_top_reset`, `tb_cnn_wrapper_reset` | mid-frame reset recovery is bit-exact afterwards |
| `tb_system_top_taps` | **inter-layer taps** — localises a numeric fault to a layer instead of leaving it as "the logits are wrong" |
| `tb_system_top_regression` | five golden beats through `ecg_accel_top`, FSM returns to idle each time |
| `CNN_wrapper_tb` | five golden beats through the **packaged AXI IP**, plus CTRL/STATUS/GIE/IER/ISR, the interrupt, ISR write-1-to-clear, `TLAST`, exactly-five-output-beats, and back-to-back frames |
| `tb_system`, `tb_system_irq_restart` | the whole block design through the Zynq VIP and AXI DMA — PS DDR in, PS DDR out, completion interrupt, mid-frame restart |

The parallel-engine tests are thin wrappers that parameterise one shared harness in
[`../04_verification/01_RTL_unit_testbenches/common/`](../04_verification/01_RTL_unit_testbenches/common/).
That harness also re-implements the banked-ROM lane/tap mapping independently of the RTL, so it
is a second opinion on §4 of [02_rtl_microarchitecture.md](02_rtl_microarchitecture.md), not a
copy of it.

## 4. Running it

```bash
python3 04_verification/03_automated_regression/run_regression.py --suite smoke
python3 04_verification/03_automated_regression/run_regression.py --suite core
python3 04_verification/03_automated_regression/run_regression.py --suite stress
python3 04_verification/03_automated_regression/run_regression.py --test CNN_wrapper_tb
python3 04_verification/03_automated_regression/verify_weights.py
```

Requires Icarus Verilog (`iverilog` / `vvp`). Golden ROMs and vectors are staged into
`.regression_work/runtime/` so the RTL's relative `$readmemh` paths resolve exactly as they do
in the verified flow.

### How a run is scored — fail-closed

Three conditions must all hold:

1. the process exits 0;
2. **no** output line matches the diagnostic pattern (`[FAIL]`, `[ERROR]`, `mismatch`,
   `$readmemh`, `fatal`, `sorry:`, …) outside a short, reviewable waiver list;
3. the testbench printed its own `[SUCCESS]` token.

An unfamiliar class of simulator complaint therefore goes **red**, not unnoticed. And before any
simulation starts, `preflight_data()` asserts that every `$readmemh` target the test will open
actually exists — including the five sample paths `CNN_wrapper_tb` builds with `$sformatf`,
which a literal-only scanner would miss.

That preflight exists for one reason: an unresolvable `$readmemh` leaves the memory at `X` and
the simulation runs to completion **comparing garbage**. It does not announce itself.

## 5. The defect that justifies gate-level simulation

First silicon bring-up: the datapath worked, latency was right, the predicted class was correct
on all five reference beats — **but the logits were not bit-exact**, while RTL simulation matched
golden exactly.

| | sample_0 logits |
| :--- | :--- |
| Golden / RTL simulation | `0453 ff30 fa81 fac1 fb28` |
| Hardware (before fix) | `0454 ff28 fad0 fa24 fbbe` |

Ruled out first, so none should be re-investigated: input staging (the host reads the frame back
from DDR), memory ordering (`dsb sy` barriers, no change), weights (the 52 ROM files are
md5-identical between synthesis and simulation), non-determinism (repeated runs bit-identical).

That left a divergence between the RTL and the implemented netlist.

**The decisive experiment** was to simulate the synthesised netlist with the same testbench that
passes on RTL:

| Run | Result | Evidence |
| :--- | :--- | :--- |
| Pre-fix netlist, full `CNN_wrapper` | **37 PASS / 12 FAIL** — and it reproduced the silicon logits **bit for bit** | [`../04_verification/06_verification_evidence/02_post_synthesis_utilization/sim_postsynth_before_fix.log`](../04_verification/06_verification_evidence/02_post_synthesis_utilization/sim_postsynth_before_fix.log) |
| Post-fix netlist, same harness | **39 PASS / 0 FAIL** | [`sim_postsynth_after_fix.log`](../04_verification/06_verification_evidence/02_post_synthesis_utilization/sim_postsynth_after_fix.log) |

Reproducing silicon in simulation is what made the rest tractable: it exonerated
implementation, the bitstream, the PS–PL path, the Linux driver and the board in one step.

**Localising it** — each layer was synthesised out-of-context and replayed through a harness
derived mechanically from the committed golden harness:

| Layer | Mismatching beats | Verdict |
| :--- | ---: | :--- |
| **conv1** | **1678 / 2928** | **FAIL** |
| conv2 … conv6, fc1, fc2 | 0 | PASS |

Logs and utilization:
[`../04_verification/06_verification_evidence/01_convolution_layer_synthesis/`](../04_verification/06_verification_evidence/01_convolution_layer_synthesis/).
The sweep demonstrably goes red, so its greens carry evidence.

**Root cause and fix** are in [02_rtl_microarchitecture.md](02_rtl_microarchitecture.md) §9.
Measured at conv1 scope:

| Variant | LUT | FF | SRL16E | Mismatching beats |
| :--- | ---: | ---: | ---: | ---: |
| base (broken) | 591 | 1 131 | 16 | **1678** |
| `ram_style = "registers"` | 591 | 1 131 | 16 | **1678** |
| `shreg_extract = "no"` | 625 | 1 211 | **0** | **0** |

`ram_style` is **inert here** — identical utilization, identical failures, bit for bit. Recorded
so nobody repeats the experiment hoping otherwise.

**Re-verified on silicon:** 5/5 reference beats, 25/25 logits bit-exact; accuracy 97.07 % →
**98.16 %**, macro-F1 0.8677 → **0.8902**. The chain closes:

```
netlist before fix  =  hardware before fix     (23/23 logits)
netlist after fix   =  golden reference        (samples 0 and 1, 10/10 logits)
hardware after fix  =  golden reference        (5 samples, 25/25 logits)
```

## 6. Negative controls

| Gate | Control | Observed |
| :--- | :--- | :--- |
| `verify_weights.py` | flip one bit in a conv6 bank file | **FAIL**, exit 1, named `addr=99 lane=9 tap=1 (out_ch=9 in_ch=99 k=1)` |
| `verify_weights.py` | **swap two slots within one word** (multiset unchanged) | **FAIL** — conservation reported `OK`, the mapping check caught it. This is what proves the mapping check earns its keep |
| `verify_weights.py` | remove `.FILE23(...)` from `ecg_accel_top.sv` | **FAIL** — `ecg_banked_rom_24 was given 23 FILE parameters` |
| `run_regression.py` | remove one weight ROM | **FAIL** before simulating, named the file |
| `run_regression.py` | remove one golden tap vector | **FAIL** before simulating, named the file |
| `run_regression.py` | remove `sample_3` (paths built with `$sformatf`) | **FAIL** before simulating, named both missing files |
| per-layer netlist sweep | the sweep itself goes red on conv1 while passing conv2–fc2 | demonstrated, §5 |

Recorded in
[`../04_verification/03_automated_regression/RESULTS.md`](../04_verification/03_automated_regression/RESULTS.md).

## 7. Numeric envelope

| Property | Value |
| :--- | :--- |
| Activation saturation events, full test set | **0 of 687 343 124** |
| Worst accumulator headroom | **12 bits** of 40 |
| Largest weight magnitude | 1.301697 vs representable 1.999939 |

**This is also a coverage hole.** Zero real-data saturation events means the RTL's saturation
logic is never exercised by dataset-driven tests. Only randomised stress reaches it. Do not read
"accuracy passes" as "saturation is correct".

## 8. What is not covered

| Gap | Consequence |
| :--- | :--- |
| No formal property verification, no UVM | Coverage is directed plus constrained-random stress. No formal proof of any property. |
| No code or functional coverage database | "26/26 pass" is a pass count, not a coverage metric. |
| No automated gate asserting `LUT as Shift Register == 0` inside `CNN_wrapper` | The defect class of §5 can recur silently on a future `PAR_OUT`/`K_PAR` change. **Highest-value outstanding work.** |
| Gate-level run covered 2 of 5 samples | Stopped by owner decision; silicon then covered all five. |
| No post-route (SDF) timing-annotated simulation | Gate-level simulation here is functional only. |
| Saturation logic uncovered by real data | §7 |
| Reference beats are all class N | `sample_0`..`sample_4` are a strong *bit-exactness* check and a weak *classification* check; the 21 892-beat run is what covers classification. |
| Single placement seed, single corner | The +0.012 ns hold margin has not been shown stable across seeds. |

## 9. Simulation traps

Each produced a run that completed and printed plausible numbers while measuring the wrong thing.

| Trap | Symptom | Guard now in place |
| :--- | :--- | :--- |
| Staged data deleted between script generation and run | every `$readmemh` silently reads nothing; failure surfaces minutes later as `AXI4_ERRS_RDATA_X` | `tb_system` and `tb_system_irq_restart` `$fatal` at time 0 if golden vectors are `X`; `run_regression.py` preflights every path |
| Zynq VIP backdoor `read_mem()` never sees PL writes through `S_AXI_HPC0_FPD` | a correct DMA output reads back as the prefill pattern — a false failure | check DMA output by snooping the S2MM AXI write channel; `read_mem()` is informational only |
| AXI DMA over-reads the input buffer | protocol checker fires a whole frame after the cause | testbenches pad the DDR input buffer to a 64-byte boundary |
| Concurrent SVA on XSim at this scale | 10 000 cycles in 49.8 s and worsening | AXI protocol rules are clocked **procedural** checks; SVA forms sit behind `USE_SVA`, default 0 |
| Vivado batch wrappers split unquoted `name=value` arguments on the `=` | `-generic_top REGISTERED_MATH=0` silently becomes two arguments | the two DUT builds are selected by **separate top modules**, not generics |

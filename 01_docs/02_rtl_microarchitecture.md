# RTL microarchitecture

**Audience: RTL design.** What the accelerator is, what it guarantees, and what must not be
changed without re-proving bit-exactness.

Sources: [`../03_rtl/01_CNN_accelerator_IP/src/`](../03_rtl/01_CNN_accelerator_IP/src/).
Target `xck26-sfvc784-2LV-c`, Vivado 2024.2, 100 MHz, one PL clock domain,
IP `xilinx.com:user:CNN_wrapper:3.0`.

---

## 1. Layer topology

A streaming 1D CNN. Every layer is an AXI4-Stream stage: no intermediate feature map is written
to DDR, and no layer waits for its predecessor to finish a frame.

| # | Layer | In ch | Out ch | K | Steps in → out | Engine | DSP48E2 |
| ---: | :--- | ---: | ---: | ---: | :--- | :--- | ---: |
| 1 | conv1 + ReLU | 1 | 16 | 5 | 187 → 183 | P16 | 16 |
| 2 | conv2 + ReLU | 16 | 16 | 5 | 183 → 179 | P4 | 4 |
| 3 | maxpool1 | 16 | 16 | 2 (s2) | 179 → 89 | serial | 0 |
| 4 | conv3 + ReLU | 16 | 32 | 3 | 89 → 87 | P4 | 4 |
| 5 | conv4 + ReLU | 32 | 32 | 3 | 87 → 85 | P8 | 8 |
| 6 | maxpool2 | 32 | 32 | 2 (s2) | 85 → 42 | serial | 0 |
| 7 | conv5 + ReLU | 32 | 256 | 3 | 42 → 40 | P16 | 16 |
| 8 | conv6 + ReLU | 256 | 256 | 3 | 40 → 38 | **P32 × K_PAR 3** | **96** |
| 9 | global maxpool | 256 | 256 | — | 38 → 1 | fused with ReLU | 0 |
| 10 | fc1 + ReLU | 256 | 64 | — | — | P16 | 16 |
| 11 | fc2 + ReLU | 64 | 64 | — | — | P8 | 8 |
| 12 | fc3 | 64 | 5 | — | — | serial | 1 |
| | | | | | | **Total** | **169** |

Dimensions are authoritative in
[`../03_rtl/01_CNN_accelerator_IP/src/ecg_params.sv`](../03_rtl/01_CNN_accelerator_IP/src/ecg_params.sv)
(`package ecg_params_pkg`).

**conv6 dominates the design.** At 256 × 256 × 3 it holds 3 145 728 weight bits — 96 BRAM tiles,
exactly its data — and 96 of the 169 DSPs. Every Phase-2 architectural decision was ultimately
about keeping conv6 fed.

## 2. Module map

| File | Role |
| :--- | :--- |
| `CNN_wrapper.sv` | AXI4-Lite register bank, AXI4-Stream adapters, interrupt |
| `ecg_accel_top.sv` | the layer chain and all ROM instantiation |
| `conv1d_parallel_stream.sv` | the parallel convolution engine |
| `linear_layer_parallel_stream.sv` | the parallel linear engine (fc1, fc2) |
| `linear_layer_stream.sv` | the serial linear engine (fc3) |
| `maxpool1d_stream.sv`, `relu_stream.sv` | pooling and activation stages |
| `relu_global_maxpool1d_stream.sv` | the fused ReLU + global-max tail |
| `axis_stream_fifo.sv` | the conv6 input decoupling FIFO |
| `ecg_banked_weight_roms.sv` | 1/2/4/24-bank ROM wrappers and the distributed-ROM variants |
| `q_round_saturate.sv` | the rounding and saturation primitive |
| `ecg_params.sv` | **authoritative** layer dimensions and widths |

## 3. Arithmetic contract — frozen

| Quantity | Format | Width |
| :--- | :--- | ---: |
| Inputs, activations | `Q8.8` | 16 |
| Weights, biases | `Q2.14` | 16 |
| Accumulator | `Q18.22` | 40 |

- In-layer requantization: `(acc + (1 << (shift-1))) >> shift` — **round half up**.
- Offline quantization (`to_fixed`): **round half to even**.
- Bias is stored at the weight fraction width and shifted **up** to the accumulator's
  `x_frac + w_frac`, never rounded down.
- Saturation clamps to the Q-format range at three sites.

**Two rounding modes coexist deliberately and must not be unified.** Bit-exactness against every
golden vector depends on both. The reference implementation of the same arithmetic is
[`../02_model/04_quantization_and_data_tools/fixed_ops.py`](../02_model/04_quantization_and_data_tools/fixed_ops.py).

Measured over the full 21 892-beat test set: **zero saturation events** in 687 343 124
accumulator requantizations, worst-case accumulator headroom **12 bits** of 40, largest weight
magnitude 1.301697 against a representable 1.999939. The Q-formats are not marginal.

## 4. Weight storage and the banked ROM contract

247 632 scalar weights. conv4, conv5 and conv6 do **not** read the scalar
`[out_channel][in_channel][kernel]` arrays — those are repacked offline into wide banked ROMs so
that `PAR_OUT` output lanes, and for conv6 `K_PAR` kernel taps as well, are fetched in one cycle.

| Layer | Geometry | ROM |
| :--- | :--- | :--- |
| conv4 | `PAR_OUT=8`, `K_PAR=1` | `ecg_banked_rom_2`, 2 banks × 384 words |
| conv5 | `PAR_OUT=16`, `K_PAR=1` | `ecg_banked_rom_4`, 4 banks × 1536 words |
| conv6 | `PAR_OUT=32`, `K_PAR=3` | `ecg_banked_rom_24`, 24 banks × 2048 words |

Each bank is 64 bits wide, so one line holds 4 × 16-bit slots, and bank *b* occupies bits
`[64*b +: 64]` — **FILE0 is the least significant bank**.

The address/slot contract, as `conv1d_parallel_stream` implements it:

```
TERMS       = IN_CH * K
K_GROUPS    = K / K_PAR
ISSUE_TERMS = IN_CH * K_GROUPS
OUT_GROUPS  = OUT_CH / PAR_OUT

group = addr // ISSUE_TERMS
issue = addr %  ISSUE_TERMS
ic    = issue // K_GROUPS
kg    = issue %  K_GROUPS

slot(lane, kp) = lane * K_PAR + kp
scalar_index   = (group * PAR_OUT + lane) * TERMS + ic * K + kg * K_PAR + kp
```

A transposition anywhere in this repack is invisible to every shape check and yields a design
that runs perfectly and computes the wrong answer. It is therefore checked independently by
[`../04_verification/03_automated_regression/verify_weights.py`](../04_verification/03_automated_regression/verify_weights.py),
which re-derives all 224 256 conv4–conv6 weights in the direction the RTL consumes them.

> **URAM is not an option on this part.** It would free ~96 BRAM tiles, but this device rejects
> non-zero URAM initialisation (`[Synth 8-10226]`) and `$readmemh` silently falls back to BRAM.
> Tested, not assumed.

> **Build trap.** The RTL loads weights through repository-relative `$readmemh` paths
> (`datasets/golden_fixed/weights_hex/...`). Simulation and synthesis run from their own working
> directories, where those paths do not resolve unless something stages the files first. The
> synthesis pre-hook
> [`../03_rtl/03_Vivado_IP_build_scripts/stage_cnn_ip_weights.tcl`](../03_rtl/03_Vivado_IP_build_scripts/stage_cnn_ip_weights.tcl)
> does this; `run_regression.py` stages into `.regression_work/runtime/`. If staging ever fails,
> **all 52 ROMs read as `X`** and the design computes garbage while appearing to build normally.

## 5. Streaming structure

Three structural features carry the 4.23× speed-up over the Phase-1 serial design, and all three
came from measurement rather than intuition:

| Feature | What it does | Why |
| :--- | :--- | :--- |
| Input decoupling FIFO before conv6 | `axis_stream_fifo`, depth 256, distributed RAM | conv6 was starved 41.8 % of the time; an AXI4-Stream handshake census separating *starved* from *blocked* per stage found it |
| Output ping-pong in every conv engine | a finished output group is snapshotted so the MAC array starts the next immediately | worthless while conv6 was starved; only paid off after decoupling |
| Fused ReLU + global-max tail | replaces two stream stages with one | shortens the tail without deleting the conv6/relu6 golden taps |

Frame latency is effectively **independent of output backpressure** — 103 208 / 103 210 /
103 250 cycles at 0 / 30 / 80 % output stall — because a frame emits only five beats. Evidence:
[`../04_verification/06_verification_evidence/04_inter_layer_tap_census/`](../04_verification/06_verification_evidence/04_inter_layer_tap_census/).

## 6. AXI interfaces

`CNN_wrapper` presents three interfaces and one interrupt. The port list has been **unchanged
since v1.6**: 30/30 signatures, 6/6 bus interfaces, 4/4 parameter defaults.

### AXI4-Lite control (`s_axi`)

| Offset | Register | Bits |
| ---: | :--- | :--- |
| `0x00` | `CTRL` | 0 = start inference · 1 = clear done/IRQ state |
| `0x04` | `STATUS` | done (sticky) · idle · busy |
| `0x08` | `GIE` | global interrupt enable |
| `0x0C` | `IER` | done-interrupt enable |
| `0x10` | `ISR` | done-interrupt status, **write 1 to clear** |

### AXI4-Stream (`s_axis` in, `m_axis` out)

16-bit `TDATA` with `TVALID` / `TREADY` / `TLAST`. Input is 187 beats; output is exactly 5 beats
with `TLAST` on the fifth. Back-to-back frames need no reset between them.

### Interrupt

`interrupt` → `xlconcat_0` input 2 → `axi_intc_0` → `pl_ps_irq0`.

## 7. Memory map and frame layout

| Peripheral | Base | Size | INTC input |
| :--- | :--- | ---: | ---: |
| `axi_intc_0` | `0x8000_0000` | 64 KB | — (PS IRQ 89) |
| `axi_dma_0` | `0x8001_0000` | 64 KB | 0 = MM2S done, 1 = S2MM done |
| `CNN_wrapper_0` | `0x8002_0000` | 4 KB | 2 = CNN done |

The device-tree node is `CNN_wrapper@80020000` with
`compatible = "xlnx,CNN-wrapper-3.0"`, so a board can be checked against the bitstream it is
actually running.

| | |
| :--- | :--- |
| Input | 187 samples, each a signed `Q8.8` in the **low half of a 32-bit word** → 748 B at `+0x0000` |
| Output | 5 logits × 16 bit → 10 B at `+0x1000` |

The 32-bit packing exists because MM2S is 32 bits wide and the subset converter takes
`tdata[15:0]`.

Two orderings are load-bearing, and both mirror
[`../04_verification/02_PS_PL_integration_testbenches/tb_system.sv`](../04_verification/02_PS_PL_integration_testbenches/tb_system.sv),
the verified reference:

1. **Arm S2MM before starting the CNN**, so the output can never be back-pressured by an
   unconfigured receive channel.
2. **Write MM2S `LENGTH` last** — that write launches the transfer.

> **DMA over-read.** The datamover fetches whole 64-byte bursts, so a 748-byte frame is read as
> **768 bytes**. Harmless on hardware *provided the bytes are mapped* — which is why the input
> buffer must be page-aligned (`dma_alloc_coherent` gives this for free) and the output sits a
> page away. In simulation the extra bytes are `X` and the Zynq VIP's protocol checker fires
> `AXI4_ERRS_RDATA_X` **a whole frame after** the frame that caused it, because the over-read
> burst is still outstanding when the DMA reports completion.

## 8. Clocking

One PL clock domain: `clk_wiz_0` `clk_out1` at 100 MHz, derived from the PS `PL_CLK_0_BUFG`,
with `proc_sys_reset_2` producing active-low `peripheral_aresetn`.

> `clk_wiz_0` **must** carry `CONFIG.PRIM_SOURCE = Global_buffer`. Its `clk_in1` is driven by a
> BUFG inside the device, not by a pin. Left at the default
> `Single_ended_clock_capable_pin`, the wizard emits its own `create_clock` on `clk_in1`, which
> lands downstream of the PS's `clk_pl_0` on the same tree and silently overrides it —
> `TIMING-2` and `TIMING-4` critical warnings, with `clk_out1` generated from a fictitious clock
> and the processor clock's insertion delay discarded. Re-check after any block-design
> regeneration that recreates the wizard;
> [`../05_fpga/03_timing_closure_study/fix_clk_wiz_primary_clock.tcl`](../05_fpga/03_timing_closure_study/fix_clk_wiz_primary_clock.tcl)
> applies it.

## 9. The one synthesis attribute that must stay

`conv1d_parallel_stream.sv` carries `(* shreg_extract = "no" *)` on `window_buf`.

At the **conv1 geometry only** — `IN_CHANNELS = 1`, so the array degenerates to `KERNEL_SIZE`
words of a single `DATA_WIDTH` bus — Vivado matches the sliding-window pattern and infers
**16 × SRL16E**, one per data bit, driving the read index onto the SRL address port. That is a
different machine from the one the RTL describes. Without the attribute, 1678 of 2928 beats
diverge in the netlist while **every RTL test stays green**, and the silicon computes wrong
logits.

Post-route, `CNN_wrapper` must show **SRL = 0**. Verify it in
[`../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/utilization_hierarchical.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/utilization_hierarchical.rpt).
The full account is [03_verification_strategy.md](03_verification_strategy.md) §5.

## 10. Implemented results

| | Value |
| :--- | ---: |
| WNS / TNS | **+1.733 ns** / 0.000 ns |
| WHS / THS | **+0.012 ns** / 0.000 ns |
| CLB LUTs | 23 987 (20.48 %) |
| CLB Registers | 39 800 (16.99 %) |
| **Block RAM** | **130 / 144 (90.28 %)** |
| DSP48E2 | 169 (13.54 %) |

`CNN_wrapper` alone: LUT 19 902, LUTRAM 100, **SRL 0**, FF 33 351, RAMB36 126, RAMB18 2,
DSP 169.

The worst setup path is inside conv6 and is 92 % routing:
`conv6/gen_real_math.issue_ic_reg[2]` → a conv6 DSP `A[18]` input, 7.465 ns, 6 logic levels.
Raising the clock means restructuring conv6's wide indexed access in RTL, not retuning the MMCM.
See [04_fpga_implementation.md](04_fpga_implementation.md) §3.

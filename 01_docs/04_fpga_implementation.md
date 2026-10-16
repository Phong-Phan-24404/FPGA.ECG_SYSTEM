# FPGA implementation and bring-up

**Audience: FPGA engineering.** How the design is built, what it closed at, and how it reaches
a running board.

Collateral: [`../05_fpga/`](../05_fpga/).

---

## 1. Tool and target

| | |
| :--- | :--- |
| Vivado | **2024.2** (win64, build 5239630) |
| Part | `xck26-sfvc784-2LV-c` |
| Board part | `xilinx.com:kv260_som:part0:1.4` |
| Accelerator IP | `xilinx.com:user:CNN_wrapper:3.0` |
| PL clock | 100 MHz, single domain |
| Board image | Kria Starter Kit, kernel `5.15.0-1027-xilinx-zynqmp` |

## 2. Released build

Every figure below is in
[`../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/00_headline.txt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/00_headline.txt),
extracted from the reports beside it.

| | Synthesis | Post-route |
| :--- | ---: | ---: |
| WNS | +4.662 ns | **+1.733 ns** |
| TNS | 0.000 ns | 0.000 ns |
| WHS | −0.082 ns *(see note)* | **+0.012 ns** |
| THS | −433.982 ns *(see note)* | 0.000 ns |
| Timed endpoints | 119 474 | 119 186 |

> **Synthesis-stage hold slack is negative, and that is normal.** Before placement and routing
> the tool has no route delays, so hold is not meaningful. The post-route column signs off:
> `WHS +0.012 ns`, `THS 0.000 ns`, zero failing endpoints, *"All user specified timing
> constraints are met."*

| Resource | Used | Available | Util % |
| :--- | ---: | ---: | ---: |
| CLB LUTs | 23 987 | 117 120 | 20.48 |
| CLB Registers | 39 800 | 234 240 | 16.99 |
| CLB (slices occupied) | 7 105 | 14 640 | **48.53** |
| **Block RAM Tile** | **130** | **144** | **90.28** |
| URAM | 0 | 64 | 0.00 |
| DSP48E2 | 169 | 1 248 | 13.54 |

Per instance
([`utilization_hierarchical.rpt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/utilization_hierarchical.rpt)):

| Instance | LUT | LUTRAM | **SRL** | FF | RAMB36 | RAMB18 | DSP |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `CNN_wrapper_0/inst` | 19 902 | 100 | **0** | 33 351 | 126 | 2 | 169 |
| `axi_dma_0` | 1 201 | 8 | 97 | 1 768 | 2 | 0 | 0 |
| `axi_smc_1` | 2 084 | 590 | 34 | 3 693 | 0 | 0 | 0 |
| `axi_smc` | 597 | 0 | 1 | 776 | 0 | 0 | 0 |

**Two readings to keep separate.** LUT usage is 20 %, but **CLB occupancy is 48.5 %**, because
the placer spreads logic to reach the BRAM columns. When judging how much room is left for
another PL block, 48.5 % is the honest figure — and **BRAM at 90.28 % is what actually binds**,
leaving 14 tiles.

**`SRL = 0` inside `CNN_wrapper` is load-bearing, not incidental.** See
[02_rtl_microarchitecture.md](02_rtl_microarchitecture.md) §9. Every remaining shift register in
the system belongs to Xilinx DMA and SmartConnect IP.

| Check | Result |
| :--- | :--- |
| Routing | 66 218 / 66 218 routable nets routed, **0 errors** |
| DRC | 526 checks, **0 errors** — 185 `DPIP-2`, 169 `DPOP-3`, 169 `DPOP-4`, 2 `REQP-1935`, 1 `RTSTAT-10`, all Warning |
| Methodology | 2 advisories: `CLKC-40`, `CLKC-56` |
| CDC | **empty report** — one PL clock domain, no crossings |
| Power | 3.199 W total, Tj 32.4 °C, vectorless (Medium confidence) |

Why each DRC rule is benign:
[05_results_and_known_issues.md](05_results_and_known_issues.md) §4.

## 3. The critical path

```
Source:      .../i_conv6/gen_real_math.issue_ic_reg[2]/C       (FDRE)
Destination: .../i_conv6/p_1_out__62/DSP_A_B_DATA_INST/A[18]   (DSP48E2)
Slack:       +1.733 ns
Data path:   7.465 ns   (logic 0.583 ns / 7.8 %, route 6.882 ns / 92.2 %)
Logic levels: 6         (LUT3, LUT6, MUXF7 ×2, MUXF8 ×2)
```

([`critical_path_setup.txt`](../05_fpga/02_synthesis_implementation_results/02_post_route_implementation/critical_path_setup.txt))

**92 % routing.** The ceiling is not in the clock generator — raising the clock means
restructuring conv6's wide indexed access in RTL. 100 MHz was kept by choice: the margin is
worth more than throughput nothing consumes.

## 4. The clocking defect, and why the study is not comparable

[`../05_fpga/03_timing_closure_study/`](../05_fpga/03_timing_closure_study/) holds a before/after
pair of full implementation runs.

> **Both were built against `CNN_wrapper` v1.6 — the Phase-1 *serial* datapath, 46 721 LUTs and
> 11 DSPs.** The released build is v3.0 parallel, 23 987 LUTs and 169 DSPs. **Do not compare the
> WNS or resource numbers in that folder with §2.** What carries forward is the constraint fix.

### The defect

Three Clocking Wizard outputs, two driving nothing but reset synchronisers. `axi_smc_1`
configured with two clocks though both its AXI interfaces sit on one — placing a clock-domain
crossing inside the interconnect for no reason.

That second domain was **never constrained**: the Zynq PS IP ships a `create_clock` for
`PS8_i/PLCLK[0]`, but Vivado skipped the file (`Designutils 20-1280`), leaving only the wizard's
own constraint on the hierarchical `clk_in1` pin — which Vivado itself flags as `TIMING-27`.

### What the reports show

The clearest evidence is not the slack — it is **how many endpoints the timer looked at**.

| | baseline | after clean-up |
| :--- | ---: | ---: |
| Setup endpoints analysed | 99 865 | **106 207** |
| Hold endpoints analysed | 99 **612** | **106 207** |
| WNS | +0.980 ns | +0.623 ns |
| WHS | +0.012 ns | +0.010 ns |
| Status | `write_bitstream Complete!` | `write_bitstream Complete!` |

Two things to notice:

1. **6 342 endpoints were never timed in the baseline, and a bitstream was produced anyway.**
2. In the baseline the setup and hold endpoint counts **disagree** (99 865 vs 99 612). After the
   fix they are identical. A timing report whose two halves do not cover the same design is the
   signature of this defect.

The clock lists make it explicit: the baseline defines only `clk_in1` and `clk_out2_...`; after
the fix `clk_pl_0` and `clk_pl_1` exist. Because `pl_clk0` had no clock, `report_cdc` also came
back empty — the one real crossing in the design was **invisible to the CDC checker**.

### WNS got worse, and that is the correct outcome

+0.980 → +0.623 ns. The design did not slow down; the timer finally looked at 6 342 more
endpoints and the worst of them was worse than anything it had been shown. **This is a
correctness fix to the design description, not an optimisation.**

Likewise the dead clock buffers: `opt_design` already prunes them, so post-route `BUFGCE = 1`
either way. Removing them buys no resources — it buys an accurate description. One real side
effect: `PFM.CLOCK` metadata, which had been advertising 200 MHz to any exported XSA, now
matches the hardware.

Apply with
[`fix_clk_wiz_primary_clock.tcl`](../05_fpga/03_timing_closure_study/fix_clk_wiz_primary_clock.tcl);
it is a constraints-only change. Re-check after any block-design regeneration that recreates the
wizard.

## 5. Build flow

```bash
# 1. integrate the IP and regenerate block-design output products
vivado -mode batch -source integrate_cnn_wrapper_v3.tcl

# 2. synthesis, implementation, bitstream (each writes its own report dir + headline)
vivado -mode batch -source scripts_build/01_synth.tcl
vivado -mode batch -source scripts_build/02_impl.tcl
vivado -mode batch -source scripts_build/03_bitstream.tcl
```

Expected on a clean run: `WNS=1.733 WHS=0.012 TNS=0 THS=0`, and **0 ERROR / 0 CRITICAL WARNING**
across all three logs. Roughly 10 min synthesis, 35 min implementation on an 8-core laptop.

> `01_synth.tcl` **aborts if `STEPS.SYNTH_DESIGN.TCL.PRE` is missing.** Without that hook the 52
> weight ROMs synthesise as `X` and the design builds cleanly while computing garbage. The abort
> is deliberate. The hook is
> [`../03_rtl/03_Vivado_IP_build_scripts/stage_cnn_ip_weights.tcl`](../03_rtl/03_Vivado_IP_build_scripts/stage_cnn_ip_weights.tcl).

> **Check `WHS` on every build.** Hold margin is **+0.012 ns**. It is met, but 12 ps is thin
> enough that an unrelated change can push it negative unnoticed. Treat a negative `WHS` as a
> stop, not a tuning problem.

The Vivado project and the `scripts_build/` step scripts live in the development tree and are
not published here; the commands above are the complete recipe.

## 6. Board artifacts

```bash
vivado -mode batch -source scripts_build/04_export_xsa.tcl   # .xsa handoff
bash  scripts_build/05_bit2bin.sh                            # bootgen: .bit -> .bit.bin
xsct  scripts_build/06_createdts.tcl                         # device-tree sources
bash  scripts_build/06b_compile_dtbo.sh                      # dtc: pl.dtsi -> pl.dtbo
bash  scripts_build/07_assemble.sh                           # lay out the firmware app dir
```

**Why `.bit.bin`.** Linux's `fpga_manager` on ZynqMP loads a `.bin`, not Vivado's `.bit`: the
`.bit` carries a variable-length ASCII header and is bit-swapped for JTAG. `bootgen
-process_bitstream bin` strips it. The `.bif` must name `[destination_device = pl]`, or bootgen
builds a full boot image instead.

### Three Vivado 2024.2 install quirks that break `createdts`

1. **XSCT lives at `C:\Xilinx\Vivado\2024.2\xsct-trim\bin\xsct.bat`** — unified Vitis 2024.2
   ships no `xsct`. That trimmed copy is missing `scripts/hsm/` entirely; copy it from
   `C:\Xilinx\Vivado\2024.2\scripts\hsm` (purely additive, same version) or `createdts` dies
   with *"couldn't read file .../xillib_internal.tcl"*.
2. **`createdts` treats a path as absolute only if it starts with `/`.** A Windows `D:/...`
   `-hw` argument is reported as *"HW project does not exist"*. Launch XSCT with its working
   directory set to the folder holding the `.xsa` and pass `-hw` as a bare filename.
3. **`createdts` ends with "Failed to build the bsp sources"** because `make` is absent on
   Windows. **That failure is harmless** — the device-tree sources are already written; only the
   (empty, for a `device_tree` domain) BSP library step failed.

Run `createdts` **without** `-board`: there is no KV260/K26 entry in `device-tree-xlnx`'s
`kernel_dtsi` board list, and the Kria image supplies the base tree, so a board dtsi would
collide with it. Only `pl.dtsi` matters. Clone `device-tree-xlnx` at `xlnx_rel_v2024.2` and pass
`-local-repo`; that also stops `createdts` from `cd`-ing away, which is what keeps quirk 2's
workaround valid.

> Keep `firmware-name` in the overlay equal to the `.bit.bin` filename actually shipped —
> `dfx-mgr` reads it to pick the bitstream.

Result: [`../05_fpga/04_KV260_deployment/`](../05_fpga/04_KV260_deployment/).

## 7. Deploy and run

```bash
sudo mkdir -p /lib/firmware/xilinx/kv260-cnn
sudo cp kv260-cnn.bit.bin kv260-cnn.dtbo shell.json /lib/firmware/xilinx/kv260-cnn/

sudo xmutil unloadapp
sudo xmutil loadapp kv260-cnn        # -> "loaded to slot 0"
```

`axi_intc`, `axi_dma` and `zocl` then probe. **Two benign messages always appear**, and neither
affects the datapath:

- a batch of *"memory leak will occur if overlay removed"* warnings;
- `zocl: IRQ index 0 not found`, because the device-tree generator makes `zocl` claim all 32 INTC
  lines while the DMA already owns inputs 0 and 1.

Then the host side ([`../06_software/01_Linux_DMA_driver/`](../06_software/01_Linux_DMA_driver/)):

```bash
cd ~/app && make && sudo ./run_all.sh
```

Expected: `samples bit-exact vs golden: 5   differing: 0`, 1.038–1.041 ms per transaction.

**Why a kernel module is needed.** The AXI DMA is a bus master: it takes a raw physical address
and writes DDR directly, bypassing the MMU. Ordinary `malloc` memory is virtually contiguous but
physically scattered and movable. `pl_dmabuf` allocates one coherent CMA buffer and publishes
its physical address at `/sys/module/pl_dmabuf/parameters/phys_addr`. Two details are
load-bearing:

- **32-bit DMA mask** — this board's DDR extends past 4 GiB while the AXI DMA is built with
  `xlnx,addrwidth = 32`; the module also rejects an unaddressable buffer explicitly.
- **`dma_mmap_coherent`, not `remap_pfn_range`** — it reproduces the kernel's own attributes, so
  the user mapping is uncached exactly as the kernel's is.

`/dev/mem` can map PL registers that drivers already claim only because `CONFIG_IO_STRICT_DEVMEM`
is unset on this kernel.

## 8. Provenance of the shipped artifacts

| Link | Check |
| :--- | :--- |
| Implementation reports → published `.bit` | `system_wrapper.bit`, 7 797 810 bytes |
| Published boot artifact → what ran on the board | `kv260-cnn.bit.bin` md5 `05fbb65b50795463b8a7cea86c64f6b8` |
| Published overlay → what ran on the board | `kv260-cnn.dtbo` md5 `2eb6c60b36cbb2d6b665c9228834c7fe` |

Both board-side hashes are recorded in
[`../04_verification/06_verification_evidence/03_board_silicon_results/board_golden_check_v3.txt`](../04_verification/06_verification_evidence/03_board_silicon_results/board_golden_check_v3.txt),
so the firmware in this repository is provably the firmware that produced the silicon numbers.

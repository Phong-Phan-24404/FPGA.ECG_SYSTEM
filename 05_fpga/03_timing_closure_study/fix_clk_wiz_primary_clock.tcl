# =============================================================================
# fix_clk_wiz_primary_clock.tcl -- clear TIMING-2 and TIMING-4.
#
#   vivado -mode batch -source scripts_build/fix_clk_wiz_primary_clock.tcl
#
# Post-synthesis methodology reported two critical warnings:
#
#   TIMING-2  Invalid primary clock source pin: a primary clock is created on
#             system_i/clk_wiz_0/inst/clk_in1, which is not a clock source.
#   TIMING-4  Invalid primary clock redefinition on a clock tree: that clock is
#             defined downstream of clk_pl_0 and overrides its insertion delay
#             and waveform.
#
# Cause: clk_wiz_0 left CONFIG.PRIM_SOURCE at its default, which claims the
# input arrives on an external clock-capable pin. The wizard therefore emits
# its own create_clock for clk_in1. In this design clk_in1 is driven inside the
# device, by the PS's PL_CLK_0 global buffer, and the PS already constrains
# that tree as clk_pl_0. Two primary clocks then exist on one tree and the
# downstream one silently wins, so clk_out1 is generated from the wizard's
# clock instead of the processor's.
#
# Fix: describe the input truthfully. With PRIM_SOURCE = Global_buffer the
# wizard stops creating a primary clock and clk_pl_0 propagates through the
# MMCM, making clk_out1 a generated clock of the PS clock, as it physically is.
# This changes constraints only -- the same MMCM, the same 100 MHz.
# =============================================================================

set project_dir D:/FPGA_cc/kv260_hardware_platform

open_project [file join $project_dir kv260_hardware_platform.xpr]
set bd_file [get_files -quiet */system.bd]
open_bd_design $bd_file

set clk_wiz [get_bd_cells clk_wiz_0]
puts "INFO: PRIM_SOURCE before = '[get_property CONFIG.PRIM_SOURCE $clk_wiz]'"
set_property CONFIG.PRIM_SOURCE {Global_buffer} $clk_wiz
puts "INFO: PRIM_SOURCE after  = '[get_property CONFIG.PRIM_SOURCE $clk_wiz]'"

# The accelerator's operating point must not move.
set out1 [get_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $clk_wiz]
if {$out1 ne "100.000"} {
    error "clk_wiz_0 CLKOUT1 is $out1 MHz, expected 100.000"
}

validate_bd_design
save_bd_design

# Output products must be regenerated or synthesis reuses the old wrapper and
# the old IP-level constraints.
generate_target all $bd_file
puts "CLK_WIZ_PRIM_SOURCE_FIXED"
close_project

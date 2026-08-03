set project_dir D:/FPGA_cc/kv260_hardware_platform
set expected_repo D:/FPGA_cc/ip_repo/CNN_wrapper_v1_6
set expected_hook [file join $expected_repo scripts stage_cnn_ip_weights.tcl]
set report_dir [file join $project_dir integration_reports]
file mkdir $report_dir

proc require_equal {description actual expected} {
    if {$actual ne $expected} {
        error "$description is '$actual', expected '$expected'"
    }
    puts "CHECK_PASSED: $description = $actual"
}

open_project [file join $project_dir kv260_hardware_platform.xpr]
require_equal "Target part" [get_property PART [current_project]] xck26-sfvc784-2LV-c
require_equal "KV260 board part" [get_property BOARD_PART [current_project]] xilinx.com:kv260_som:part0:1.4
require_equal "CNN IP repository" [get_property ip_repo_paths [current_project]] $expected_repo
require_equal "CNN synthesis pre-hook" [get_property STEPS.SYNTH_DESIGN.TCL.PRE [get_runs synth_1]] $expected_hook

set bd_file [get_files -quiet */system.bd]
open_bd_design $bd_file
set cnn [get_bd_cells CNN_wrapper_0]
require_equal "CNN IP VLNV" [get_property VLNV $cnn] xilinx.com:user:CNN_wrapper:1.6
require_equal "CNN registered math" [get_property CONFIG.REGISTERED_MATH $cnn] 1
require_equal "CNN nominal clock request" [get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ [get_bd_cells clk_wiz_0]] 100.000
require_equal "CNN clock net" [get_bd_nets -quiet -of_objects [get_bd_pins /CNN_wrapper_0/s_axi_aclk]] /clk_wiz_0_clk_out2
require_equal "DMA MM2S clock net" [get_bd_nets -quiet -of_objects [get_bd_pins /axi_dma_0/m_axi_mm2s_aclk]] /clk_wiz_0_clk_out2
require_equal "PS HPC0 clock net" [get_bd_nets -quiet -of_objects [get_bd_pins /zynq_ultra_ps_e_0/saxihpc0_fpd_aclk]] /clk_wiz_0_clk_out2
require_equal "CNN input stream width (bytes)" [get_property CONFIG.M_TDATA_NUM_BYTES [get_bd_cells axis_subset_converter_0]] 2

set ps [get_bd_cells zynq_ultra_ps_e_0]
require_equal "PS PL0 enabled" [get_property CONFIG.PSU__FPGA_PL0_ENABLE $ps] 1
require_equal "PS HPM0 master enabled" [get_property CONFIG.PSU__USE__M_AXI_GP2 $ps] 1
require_equal "PS HPC0 slave enabled" [get_property CONFIG.PSU__USE__S_AXI_GP0 $ps] 1
require_equal "PS PL IRQ0 enabled" [get_property CONFIG.PSU__USE__IRQ0 $ps] 1

validate_bd_design
puts "CHECK_PASSED: block design validation"
generate_target all $bd_file
report_ip_status -file [file join $report_dir ip_status.rpt]
puts "OUTPUT_PRODUCTS_GENERATED"
close_project

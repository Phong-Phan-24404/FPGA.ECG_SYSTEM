# Upgrade the KV260 ECG hardware platform to the packaged CNN_wrapper v1.6 IP
# and place the complete accelerator data/control path in its nominal 100 MHz
# clock domain.

set project_dir D:/FPGA_cc/kv260_hardware_platform
set ip_repo D:/FPGA_cc/ip_repo/CNN_wrapper_v1_6
set synth_pre_hook [file join $ip_repo scripts stage_cnn_ip_weights.tcl]

if {![file exists [file join $project_dir kv260_hardware_platform.xpr]]} {
    error "KV260 project not found: $project_dir"
}
if {![file exists [file join $ip_repo component.xml]]} {
    error "Packaged CNN IP not found: $ip_repo"
}
if {![file exists $synth_pre_hook]} {
    error "CNN IP synthesis pre-hook not found: $synth_pre_hook"
}

open_project [file join $project_dir kv260_hardware_platform.xpr]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog

if {[llength [get_ipdefs -all xilinx.com:user:CNN_wrapper:1.6]] == 0} {
    error "Vivado did not discover xilinx.com:user:CNN_wrapper:1.6"
}

set bd_file [get_files -quiet */system.bd]
open_bd_design $bd_file

set cnn_cell [get_bd_cells CNN_wrapper_0]
if {[get_property VLNV $cnn_cell] ne "xilinx.com:user:CNN_wrapper:1.6"} {
    upgrade_bd_cells $cnn_cell
}
set cnn_cell [get_bd_cells CNN_wrapper_0]
if {[get_property VLNV $cnn_cell] ne "xilinx.com:user:CNN_wrapper:1.6"} {
    error "CNN_wrapper_0 did not upgrade to v1.6; current VLNV is [get_property VLNV $cnn_cell]"
}
set_property CONFIG.REGISTERED_MATH 1 $cnn_cell

# clk_out2 already drives the CNN control/streaming network. Change this active
# output from 200 MHz to the nominal 100 MHz operating point verified for CNN.
set clk_wiz [get_bd_cells clk_wiz_0]
set_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ 100.000 $clk_wiz

# Keep all DMA, AXI-Lite and AXI4-Stream transactions in the same generated
# clock domain. The PS PL clock remains the input to clk_wiz_0.
set system_clk_source [get_bd_pins -quiet /clk_wiz_0/clk_out2]
if {[llength $system_clk_source] != 1} {
    error "Could not resolve clk_wiz_0/clk_out2"
}
foreach pin_path {
    /axi_dma_0/m_axi_mm2s_aclk
    /zynq_ultra_ps_e_0/saxihpc0_fpd_aclk
} {
    set pin [get_bd_pins $pin_path]
    set old_net [get_bd_nets -quiet -of_objects $pin]
    if {[llength $old_net] != 0} {
        disconnect_bd_net $old_net $pin
    }
    connect_bd_net $system_clk_source $pin
}

# The DMA emits 32-bit stream beats, while the CNN consumes signed 16-bit ECG
# samples. Keep the low 16 bits and drop TKEEP before the CNN input FIFO.
set input_converter [get_bd_cells axis_subset_converter_0]
set_property -dict [list \
    CONFIG.M_TDATA_NUM_BYTES {2} \
    CONFIG.M_HAS_TKEEP {0} \
    CONFIG.TDATA_REMAP {tdata[15:0]} \
    CONFIG.TKEEP_REMAP {1'b0}] $input_converter

# The CNN RTL resolves its model files relative to the synth_1 run directory.
set_property STEPS.SYNTH_DESIGN.TCL.PRE $synth_pre_hook [get_runs synth_1]

validate_bd_design
save_bd_design

puts "INTEGRATION_SUCCESS"
puts "  CNN=[get_property VLNV $cnn_cell]"
puts "  CNN_CLOCK=[get_bd_nets -quiet -of_objects [get_bd_pins /CNN_wrapper_0/s_axi_aclk]]"
puts "  CLOCK_WIZ_OUT2=[get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $clk_wiz] MHz"
puts "  SYNTH_PRE_HOOK=$synth_pre_hook"
close_project

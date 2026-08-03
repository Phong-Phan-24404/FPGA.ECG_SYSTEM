# Clean synthesis test for the KV260 system after CNN IP integration.
set project_dir D:/FPGA_cc/kv260_hardware_platform
set report_dir [file join $project_dir integration_reports]
file mkdir $report_dir

open_project [file join $project_dir kv260_hardware_platform.xpr]
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1

set run_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$run_status"
if {![string match "synth_design Complete!*" $run_status]} {
    error "System synthesis did not complete successfully: $run_status"
}

open_run synth_1
report_timing_summary -file [file join $report_dir system_synth_timing_summary.rpt]
report_utilization -file [file join $report_dir system_synth_utilization.rpt]
report_drc -file [file join $report_dir system_synth_drc.rpt]
close_project

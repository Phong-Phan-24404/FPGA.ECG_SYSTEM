# Vivado synthesis pre-hook for a project that consumes the packaged CNN IP.
#
# This script is copied into every IP release under scripts/.  Set it as the
# consumer project's synth_1 pre-hook.  Vivado runs the hook from the synthesis
# run directory, where the RTL's $readmemh paths are resolved.

set script_dir   [file normalize [file dirname [info script]]]
set package_root [file normalize [file join $script_dir ..]]
set source_dir   [file join $package_root datasets golden_fixed weights_hex]
set target_dir   [file normalize [file join [pwd] datasets golden_fixed weights_hex]]

if {![file isdirectory $source_dir]} {
    error "CNN IP weight directory is missing: $source_dir"
}

set weight_files [glob -nocomplain -types f [file join $source_dir *.hex]]
if {[llength $weight_files] != 18} {
    error "Expected 18 CNN IP .hex weight files in $source_dir; found [llength $weight_files]."
}

file mkdir $target_dir
foreach weight_file $weight_files {
    file copy -force $weight_file $target_dir
}

puts "INFO: Staged [llength $weight_files] CNN IP weight files to $target_dir"

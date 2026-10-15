# Vivado synthesis pre-hook for projects consuming CNN_wrapper v3.
#
# Vivado runs synthesis from the run directory, while the RTL uses repository-
# relative $readmemh paths. Copy the packaged ROM files into that directory so
# every initialization path resolves exactly as it does in the canonical repo.

set script_dir   [file normalize [file dirname [info script]]]
set package_root [file normalize [file join $script_dir ..]]
set source_dir   [file join $package_root 02_weight_ROM_reference]
set target_dir   [file normalize [file join [pwd] datasets golden_fixed weights_hex]]

if {![file isdirectory $source_dir]} {
    error "CNN v3 IP weight directory is missing: $source_dir"
}

set weight_files {}
foreach f [lsort [glob -nocomplain -types f [file join $source_dir *.hex]]] {
    if {[regexp {^(conv[1-6]|fc[12])_weight\.hex$} [file tail $f]]} { continue }
    lappend weight_files $f
}
if {[llength $weight_files] != 52} {
    error "Expected 52 CNN v3 ROM .hex files in $source_dir; found [llength $weight_files]."
}

file mkdir $target_dir
foreach weight_file $weight_files {
    file copy -force $weight_file $target_dir
}

puts "INFO: Staged [llength $weight_files] CNN v3 ROM files to $target_dir"

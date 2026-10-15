# =============================================================================
# synth_ooc.tcl -- tong hop CNN_wrapper doc lap roi xuat netlist de mo phong.
#
#   cd <thu muc lam viec>
#   vivado -mode batch -source <repo>/04_verification/04_post_synthesis_verification/synth_ooc.tcl
#
# Moi thu duoc ghi ra thu muc hien hanh ([pwd]), con RTL va trong so duoc lay
# tu chinh repository nay. Chay tu mot thu muc trong de khong lam ban repo.
#
# Muc dich: lap day mat xich duy nhat chua tung duoc kiem chung trong ca du an.
# RTL da duoc chung minh bit-true tung lop (tb_system_top_taps: 0 sai tren
# ~34000 gia tri trung gian), va phan cung thi lech. Giua hai diem do chi con
# mot buoc chua ai kiem tra: viec dich RTL thanh netlist.
#
# Chi tong hop rieng CNN_wrapper, khong tong hop ca he thong, vi:
#   - Duong PS/DMA da duoc tb_system chung minh, va phan cung cung da chung to
#     no giao dung byte (cnn_run doc lai khung tu DDR truoc moi lan chay).
#   - tb_system tham chieu phan cap vao Zynq VIP (write_mem/read_mem), nhung
#     netlist sau tong hop bi lam phang nen cac tham chieu do se vo.
#   - CNN_wrapper_tb chi dung cong ngoai, nen chay duoc tren netlist phang.
#
# Netlist mang theo noi dung ROM duoi dang gia tri INIT, nen phep thu nay bat
# duoc ca truong hop tong hop nung sai trong so -- dieu ma mo phong hanh vi
# khong the phat hien.
# =============================================================================

# Source of the RTL under test. Defaults to the released IP in this repository,
# resolved from this script's own location so the checkout can live anywhere.
# Set CNN_IP_SRC to point somewhere else -- e.g. an unfixed CNN_wrapper v2.0
# tree -- to reproduce the pre-fix conv1 divergence. v2.0 is deliberately not
# published here; see historical development evidence (not shipped).
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set default_ip_src [file join $repo_root 03_rtl 01_CNN_accelerator_IP src]
set ip_src [expr {[info exists ::env(CNN_IP_SRC)] ? $::env(CNN_IP_SRC) : $default_ip_src}]
set work_dir [pwd]

if {![file isdirectory $ip_src]} {
    error "khong tim thay thu muc RTL: $ip_src (dat CNN_IP_SRC de tro di noi khac)"
}
puts "INFO: nguon RTL = $ip_src"
set part     xck26-sfvc784-2LV-c

puts "INFO: thu muc lam viec = $work_dir"

# --- trong so phai nam dung duong dan tuong doi ma RTL dung -----------------
# ecg_accel_top.sv goi $readmemh("datasets/golden_fixed/weights_hex/...") theo
# duong dan tuong doi voi thu muc chay, giong het pre-hook cua du an that.
set weight_src [file join $repo_root 03_rtl 02_weight_ROM_reference]
set weight_dst [file join $work_dir datasets golden_fixed weights_hex]
if {![file isdirectory $weight_src]} {
    error "khong tim thay thu muc trong so: $weight_src"
}
set weight_files [lsort [glob -nocomplain -types f [file join $weight_src *.hex]]]

# weights_hex cung chua ban scalar convN_weight.hex / fc1..fc2_weight.hex ma chi
# testbench dung lam tham chieu; RTL khong $readmemh chung. Dem rieng 52 tep ROM
# that su, de phep kiem "du 52" van la bang chung duong nhu truoc.
set rom_files {}
foreach f $weight_files {
    if {[regexp {^(conv[1-6]|fc[12])_weight\.hex$} [file tail $f]]} { continue }
    lappend rom_files $f
}
if {[llength $rom_files] != 52} {
    error "can dung 52 tep ROM .hex, tim thay [llength $rom_files] trong $weight_src"
}
file mkdir $weight_dst
foreach f $weight_files { file copy -force $f $weight_dst }
puts "INFO: da stage [llength $rom_files] tep ROM (tong [llength $weight_files] tep) vao $weight_dst"

# --- nguon RTL --------------------------------------------------------------
read_verilog -sv [list \
    [file join $ip_src ecg_params.sv] \
    [file join $ip_src q_round_saturate.sv] \
    [file join $ip_src axis_stream_fifo.sv] \
    [file join $ip_src ecg_banked_weight_roms.sv] \
    [file join $ip_src conv1d_parallel_stream.sv] \
    [file join $ip_src maxpool1d_stream.sv] \
    [file join $ip_src relu_stream.sv] \
    [file join $ip_src relu_global_maxpool1d_stream.sv] \
    [file join $ip_src linear_layer_stream.sv] \
    [file join $ip_src linear_layer_parallel_stream.sv] \
    [file join $ip_src ecg_accel_top.sv] \
    [file join $ip_src CNN_wrapper.sv] \
]

# out_of_context: khong chen bo dem IO, vi day la mot khoi con chu khong phai
# thiet ke muc dinh. REGISTERED_MATH=1 khop voi cau hinh CNN_wrapper_0 trong
# block design cua du an KV260.
synth_design -top CNN_wrapper -part $part -mode out_of_context \
             -generic REGISTERED_MATH=1

report_utilization -file [file join $work_dir synth_utilization.rpt]

# funcsim: netlist chuc nang bang UNISIM, khong kem thong tin tre. Day chinh la
# thu can kiem tra -- cau truc sau tong hop, khong phai tre duong day.
set netlist [file join $work_dir CNN_wrapper_funcsim.v]
write_verilog -mode funcsim -force $netlist
puts "INFO: da ghi netlist $netlist ([file size $netlist] byte)"

# Luu checkpoint de sau nay con dieu tra tiep ma khong phai tong hop lai.
write_checkpoint -force [file join $work_dir CNN_wrapper_synth.dcp]

puts "STEP_01_SYNTH_OOC_DONE"

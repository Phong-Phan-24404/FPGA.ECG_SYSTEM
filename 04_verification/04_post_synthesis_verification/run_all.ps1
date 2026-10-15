# =============================================================================
# run_all.ps1 -- mo phong chuc nang SAU TONG HOP cho CNN_wrapper.
#
#   powershell -ExecutionPolicy Bypass -File run_all.ps1
#
# Ba buoc: tong hop OOC -> mo phong netlist -> doi chieu voi lan chay hanh vi.
#
# Phep thu nay phan doi ket luan mot cach dut khoat:
#   netlist LECH golden  -> loi nam trong RTL, o cau truc mo phong dung nhung
#                           tong hop ra khac. Phai sua CNN_wrapper.
#   netlist KHOP golden  -> RTL trong sach ca sau tong hop. Loi nam o
#                           implementation, bitstream, hoac moi truong phan
#                           cung. Khong sua dong ma nao.
# =============================================================================
param(
    # Vivado 2024.2 installation directory. Override if yours lives elsewhere.
    [string]$VivadoBin = "C:\Xilinx\Vivado\2024.2\bin",
    # RTL under test. Defaults to the released IP in this repository. Point it
    # at an unfixed CNN_wrapper v2.0 tree to reproduce the pre-fix conv1
    # divergence; v2.0 is deliberately not published here -- see
    # historical development evidence (not shipped).
    [string]$IpSrc,
    # Golden vectors. Defaults to the ones shipped with the IP.
    [string]$Vectors
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$repoRoot = (Resolve-Path (Join-Path $here "..\..")).Path
if (-not $IpSrc)   { $IpSrc   = Join-Path $repoRoot "03_rtl\01_CNN_accelerator_IP\src" }
if (-not $Vectors) { $Vectors = Join-Path $repoRoot "04_verification\05_golden_test_vectors" }

$vivado = Join-Path $VivadoBin "vivado.bat"
$xvlog  = Join-Path $VivadoBin "xvlog.bat"
$xelab  = Join-Path $VivadoBin "xelab.bat"
$xsim   = Join-Path $VivadoBin "xsim.bat"

foreach ($p in @($vivado, $xvlog, $xelab, $xsim)) {
    if (-not (Test-Path $p)) {
        throw "khong tim thay cong cu Vivado: $p (dung -VivadoBin de chi duong dan khac)"
    }
}
if (-not (Test-Path $IpSrc))   { throw "khong tim thay thu muc RTL: $IpSrc" }
if (-not (Test-Path $Vectors)) { throw "khong tim thay vector vang: $Vectors" }

Write-Host "RTL    : $IpSrc"
Write-Host "vector : $Vectors"

function Say($t) { Write-Host ""; Write-Host "=== $t ===" }

# ---------------------------------------------------------------- buoc 1 ----
Say "Buoc 1: tong hop OOC CNN_wrapper"
if (Test-Path "CNN_wrapper_funcsim.v") {
    Write-Host "  netlist da co, bo qua tong hop (xoa de tong hop lai)"
} else {
    # synth_ooc.tcl reads CNN_IP_SRC, so both steps are guaranteed to compile
    # the same RTL tree. Without this they could silently diverge.
    $env:CNN_IP_SRC = $IpSrc
    & $vivado -mode batch -notrace -nojournal -log synth.log `
              -source (Join-Path $here "synth_ooc.tcl") | Out-Null
    Remove-Item Env:\CNN_IP_SRC -ErrorAction SilentlyContinue
    if (-not (Test-Path "CNN_wrapper_funcsim.v")) { throw "tong hop that bai, xem synth.log" }
}
$nl = Get-Item "CNN_wrapper_funcsim.v"
Write-Host ("  netlist: {0:N0} byte" -f $nl.Length)

# ---------------------------------------------------------------- buoc 2 ----
# Vector vang phai nam dung duong dan tuong doi ma testbench dung.
Say "Buoc 2: stage vector vang"
$dst = Join-Path $here "datasets\golden_fixed\test_vectors_hex"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
foreach ($i in 0..4) {
    $s = Join-Path $Vectors "sample_$i"
    $d = Join-Path $dst "sample_$i"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item (Join-Path $s "input.hex")  $d -Force
    Copy-Item (Join-Path $s "logits.hex") $d -Force
}
Write-Host "  da stage 5 mau vao $dst"

# ---------------------------------------------------------------- buoc 3 ----
Say "Buoc 3: bien dich"
# ecg_params.sv can cho testbench (no dung ecg_params_pkg::CONV1_IN_STEPS).
& $xvlog -sv -work work (Join-Path $IpSrc "ecg_params.sv") 2>&1 | Select-String -Pattern "ERROR|error:"
& $xvlog -work work "CNN_wrapper_funcsim.v"     2>&1 | Select-String -Pattern "ERROR|error:"
& $xvlog -sv -work work (Join-Path $here "CNN_wrapper_postsynth_tb.sv") 2>&1 | Select-String -Pattern "ERROR|error:"
# glbl.v cung cap xung GSR ma cac primitive UNISIM can luc khoi dong.
$glbl = Join-Path $VivadoBin "..\data\verilog\src\glbl.v"
if (-not (Test-Path $glbl)) { throw "khong tim thay glbl.v: $glbl" }
& $xvlog -work work $glbl 2>&1 | Select-String -Pattern "ERROR|error:"

Say "Buoc 4: elaborate"
# -L unisims_ver: thu vien primitive ma netlist funcsim tham chieu toi.
& $xelab -debug off -L unisims_ver -L secureip --snapshot ps_snapshot `
         work.CNN_wrapper_tb work.glbl 2>&1 |
    Select-String -Pattern "ERROR|error:|Built simulation"

Say "Buoc 5: chay mo phong"
# Duong dan tuyet doi kieu Windows bi Tcl hieu nham dau gach cheo nguoc
# ("un.tcl" thanh ky tu xuong dong), nen dung ten tuong doi.
"run all`nquit" | Out-File -FilePath (Join-Path $here "run.tcl") -Encoding ascii
& $xsim ps_snapshot -tclbatch "run.tcl" -log sim_postsynth.log | Out-Null

# ---------------------------------------------------------------- ket qua ----
Say "Ket qua mo phong sau tong hop"
if (-not (Test-Path "sim_postsynth.log")) { throw "khong co sim_postsynth.log" }
Get-Content "sim_postsynth.log" |
    Select-String -Pattern "PASS|FAIL|logit|bit-exact|mismatch|Sending|Finished" |
    Select-Object -Last 40 | ForEach-Object { "  $_" }

Say "Tom tat"
$log = Get-Content "sim_postsynth.log" -Raw
$fails = ([regex]::Matches($log, "\[FAIL\]")).Count
$passes = ([regex]::Matches($log, "\[PASS\]")).Count
Write-Host "  so dong PASS: $passes"
Write-Host "  so dong FAIL: $fails"
Write-Host ""
if ($fails -eq 0 -and $passes -gt 0) {
    Write-Host "  => NETLIST KHOP GOLDEN."
    Write-Host "     RTL trong sach ca sau tong hop. Loi phan cung nam o"
    Write-Host "     implementation, bitstream, hoac moi truong phan cung."
    Write-Host "     KHONG phai sua ma nguon CNN_wrapper."
} elseif ($fails -gt 0) {
    Write-Host "  => NETLIST LECH GOLDEN."
    Write-Host "     Da tai hien duoc loi phan cung bang mo phong. Loi nam trong"
    Write-Host "     RTL, o cau truc mo phong dung nhung tong hop ra khac."
    Write-Host "     Sua o CNN_wrapper / ecg_accel_top."
} else {
    Write-Host "  => khong doc duoc ket qua, xem sim_postsynth.log"
}

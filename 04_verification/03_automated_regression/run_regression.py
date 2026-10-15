#!/usr/bin/env python3
"""ECG CNN RTL regression with an integrated randomized backpressure sweep.

Runs self-checking benches in `04_verification/01_RTL_unit_testbenches`
against the RTL in `03_rtl/01_CNN_accelerator_IP/src`, scoring each run on the testbench's
own `[SUCCESS]` token plus a fail-closed scan of the simulator output.

Requires Icarus Verilog (`iverilog` / `vvp`) on PATH.

    python3 run_regression.py --suite smoke
    python3 run_regression.py --suite core
    python3 run_regression.py --suite stress          # 6 tests x 8 seeds x 5 stall rates
    python3 run_regression.py --suite all
    python3 run_regression.py --test CNN_wrapper_tb
    python3 run_regression.py --suite core --dry-run  # print commands, simulate nothing

Only RTL simulation is scored here. Lint, manifest hashing and the tiered
regression table of the development tree are deliberately out of scope.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

SUCCESS_TOKEN = "[SUCCESS]"

# --------------------------------------------------------------------------
# Repository layout. The RTL loads its weight ROMs and the testbenches load
# their golden vectors through paths that are relative to the *IP* directory:
#
#     $readmemh("datasets/golden_fixed/weights_hex/conv6_weight_p32_k3_b0.hex")
#
# so every simulation must run with a staged runtime directory as its working
# directory. Running from anywhere else leaves every ROM and every golden
# vector at X, and the design then computes garbage while the run completes
# normally. Runtime inputs are copied from 03_rtl and 04_verification/05_golden_test_vectors;
# preflight_data() refuses to start if any required golden file is missing.
# --------------------------------------------------------------------------
RTL_SUBDIR = ("03_rtl", "01_CNN_accelerator_IP", "src")
DATA_SUBDIR = ("03_rtl", "02_weight_ROM_reference")
VECTOR_SUBDIR = ("04_verification", "05_golden_test_vectors")
TB_SUBDIR = ("04_verification", "01_RTL_unit_testbenches")

# Any output line matching this is treated as a diagnostic and fails the run
# unless it also matches one of BENIGN_LINE_PATTERNS. Fail-closed by design: an
# unfamiliar class of simulator complaint must go red, not slip through.
DIAGNOSTIC_RE = re.compile(
    r"(?i)("
    r"\[fail\]|\[error\]|\[blocked\]"           # testbench verdicts
    r"|\bmismatch\b"                            # scoreboard language
    r"|\$readmem[hb]\b"                         # $readmemh/$readmemb open failures
    r"|\bunable to (open|read|bind)\b"
    r"|\b(cannot|can't|could not|couldn't) (open|find|read)\b"
    r"|\berror\b|\berrors\b"
    r"|\bfatal\b|\$fatal\b"
    r"|\bassertion\b|\bassert(ion)? fail"
    r"|\bsegmentation fault\b|\bcore dumped\b"
    r"|\btimed? ?out\b"
    r"|\bno such file\b|\bnot found\b"
    r"|\bundefined\b|\bunresolved\b"
    r"|\bsorry:\b"                              # Icarus unsupported-construct bail-out
    r")"
)

# Lines that contain a diagnostic-shaped word but are known to be harmless.
# Every entry here is a deliberate, reviewable waiver.
BENIGN_LINE_PATTERNS = [
    # Icarus compile-time notes emitted by every testbench in this repository.
    re.compile(r"warning: System task \(\$(display|finish|fatal|error)\) cannot be synthesized"),
    re.compile(r"warning: extra digits given for sized hex constant"),
    re.compile(r"warning: Numeric constant truncated to \d+ bits"),
    # Explicit "no errors" scoreboard summaries.
    re.compile(r"(?i)\b(0|zero) errors?\b"),
    re.compile(r"(?i)\berrors?\s*[:=]\s*0\b"),
    # Per-check testbench verdicts. A [PASS] line may name the condition it
    # checked ("... no mismatch", "... error flag clear"); the suite-level
    # verdict is carried by [FAIL] and by the absence of [SUCCESS], not by
    # vocabulary inside a line that already reported success.
    re.compile(r"^\[PASS\]"),
    re.compile(r"^\[MON\]"),
    re.compile(r"^\[PERF\]"),
]


def is_diagnostic(line: str) -> bool:
    """True if `line` should fail the run."""
    if not DIAGNOSTIC_RE.search(line):
        return False
    return not any(p.search(line) for p in BENIGN_LINE_PATTERNS)


def scan_output(text: str) -> str:
    """Return the first offending line, or '' if the text is clean."""
    for raw in text.splitlines():
        line = raw.strip()
        if line and is_diagnostic(line):
            return line
    return ""


# --------------------------------------------------------------------------
# Suites. Deliberately small: enough to demonstrate unit, integration and
# backpressure coverage without reproducing the development tree's tier table.
# --test runs any testbench in 04_verification/01_RTL_unit_testbenches by name.
# --------------------------------------------------------------------------
SMOKE = [
    "tb_math_helper",                 # rounding / saturation primitive
    "tb_ecg_accel_top_shape_check",   # layer dimensions match ecg_params_pkg
    "tb_ecg_accel_top_smoke",         # the full chain moves a frame
]
CORE = [
    "tb_axis_stream_fifo",            # the conv6 decoupling FIFO
    "tb_conv1d_parallel_conv6",       # the largest engine, P32 x K_PAR=3
    "tb_linear_parallel_fc1",         # the parallel linear engine
    "tb_cnn_wrapper_reset",           # mid-frame reset recovery
    "CNN_wrapper_tb",                 # AXI4-Lite + AXI4-Stream, 5 golden samples
]
STRESS = [
    "tb_chain_a", "tb_chain_b",       # chained conv -> relu -> pool paths
    "tb_conv1d_parallel_conv4",       # the three largest conv engines, swept
    "tb_conv1d_parallel_conv5",
    "tb_conv1d_parallel_conv6",
    "tb_linear_parallel_fc2",         # the parallel linear engine, swept
]

# Every testbench in 04_verification/01_RTL_unit_testbenches runs against the released IP. The
# eight Phase-1 testbenches that drove `conv1d_stream` and
# `global_maxpool1d_stream` were removed with those engines: Phase 2 replaced
# them with `conv1d_parallel_stream` and the fused
# `relu_global_maxpool1d_stream`, and CNN_wrapper v3.0 does not ship the
# superseded modules. Their results from when those engines were current are
# retained in historical development records (not included in this portfolio).
SUITES = {
    "smoke": SMOKE,
    "core": CORE,
    "stress": STRESS,
    "all": list(dict.fromkeys(SMOKE + CORE + STRESS)),
}

SEEDS = [1, 2, 3, 7, 11, 23, 42, 99]
STALL_RATES = [0, 10, 30, 50, 80]

DATA_REF_RE = re.compile(r'"(datasets/golden_fixed/[A-Za-z0-9_/.]+\.hex)"')
# CNN_wrapper_tb builds its five sample paths with $sformatf, so they carry no
# literal for the scanner to find. They are declared here instead of missed.
DYNAMIC_DATA_REFS = {
    "CNN_wrapper_tb": [
        f"datasets/golden_fixed/test_vectors_hex/sample_{i}/{f}"
        for i in range(5) for f in ("input.hex", "logits.hex")
    ],
}


def collect_sources(rtl_dir: Path, tb_dir: Path):
    """RTL plus shared testbench harnesses, with package files first.

    `ecg_params.sv` declares `package ecg_params_pkg` and `ecg_accel_top.sv`
    imports it. Both live in the same directory, where a plain alphabetical
    glob puts the importer before the package and elaboration fails. Packages
    are therefore hoisted explicitly.

    `04_verification/01_RTL_unit_testbenches/common/` holds parameterized golden harnesses, not
    tests; they are compiled for every run so that a thin wrapper such as
    `tb_conv1d_parallel_conv6` can instantiate one.
    """
    def sv_and_v(d):
        return sorted(d.glob("*.sv")) + sorted(d.glob("*.v"))

    rtl = sv_and_v(rtl_dir)
    is_pkg = re.compile(r"^\s*package\s+\w+\s*;", re.MULTILINE)
    packages = [f for f in rtl
                if is_pkg.search(f.read_text(encoding="utf-8", errors="replace"))]
    rest = [f for f in rtl if f not in packages]
    common = sv_and_v(tb_dir / "common") if (tb_dir / "common").is_dir() else []
    return packages + rest + common


def preflight_data(name, test_file, sources, data_root):
    """Return the golden files this test needs but cannot find.

    This guards the one failure mode that does not announce itself: an
    unresolvable `$readmemh` leaves the memory at X and the simulation runs to
    completion comparing garbage. Checking first turns that into a named,
    actionable failure before a single cycle is simulated.
    """
    texts = [test_file.read_text(encoding="utf-8", errors="replace")]
    texts += [s.read_text(encoding="utf-8", errors="replace") for s in sources]
    refs = set()
    for t in texts:
        refs.update(DATA_REF_RE.findall(t))
    refs.update(DYNAMIC_DATA_REFS.get(name, []))
    return sorted(r for r in refs if not (data_root / r).is_file())


def simulate(cmd, cwd, timeout):
    """Run one simulation. Returns (ok, details)."""
    try:
        proc = subprocess.run([str(v) for v in cmd], cwd=str(cwd), capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"
    except OSError as exc:
        return False, str(exc)
    output = proc.stdout + "\n" + proc.stderr
    offender = scan_output(output)
    if proc.returncode != 0:
        return False, f"exit={proc.returncode}\n{output[-2500:]}"
    if offender:
        return False, f"diagnostic: {offender}\n{output[-2500:]}"
    if SUCCESS_TOKEN not in proc.stdout:
        return False, f"missing {SUCCESS_TOKEN}\n{output[-2500:]}"
    return True, output


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project-root", type=Path,
                    default=Path(__file__).resolve().parents[2])
    ap.add_argument("--suite", choices=sorted(SUITES), default="smoke")
    ap.add_argument("--test", action="append",
                    help="Run a named testbench instead of a suite; repeatable")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the commands and exit without simulating")
    ap.add_argument("--timeout", type=int, default=900,
                    help="Per-command timeout in seconds (default 900)")
    ap.add_argument("--seeds", default=",".join(map(str, SEEDS)))
    ap.add_argument("--stall-rates", default=",".join(map(str, STALL_RATES)))
    ap.add_argument("--sweep", action="store_true",
                    help="Force the seed/stall sweep on every selected test")
    args = ap.parse_args()

    root = args.project_root.resolve()
    rtl_dir = root.joinpath(*RTL_SUBDIR)
    data_src = root.joinpath(*DATA_SUBDIR)
    vectors = root.joinpath(*VECTOR_SUBDIR)
    tb_dir = root.joinpath(*TB_SUBDIR)

    for label, path in (("RTL", rtl_dir), ("testbench", tb_dir),
                        ("weights", data_src),
                        ("vectors", vectors)):
        if not path.is_dir():
            print(f"[FAIL] {label} directory not found: {path}", file=sys.stderr)
            return 2

    sources = collect_sources(rtl_dir, tb_dir)
    if not sources:
        print(f"[FAIL] No RTL sources under {rtl_dir}", file=sys.stderr)
        return 2

    try:
        seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
        stalls = [int(s) for s in args.stall_rates.split(",") if s.strip()]
    except ValueError:
        print("[FAIL] --seeds and --stall-rates take comma-separated integers",
              file=sys.stderr)
        return 2
    if not seeds or not stalls:
        print("[FAIL] --seeds and --stall-rates must not be empty", file=sys.stderr)
        return 2

    tests = args.test or SUITES[args.suite]
    # The seed/stall sweep belongs to the stress suite. `core` shares two
    # testbenches with `stress`, so membership in STRESS alone must not trigger
    # a 40-run sweep inside a suite the user asked to be quick. --sweep is the
    # explicit opt-in for anything else, including a named --test.
    if args.sweep:
        sweep_set = set(tests)
    elif not args.test and args.suite in ("stress", "all"):
        sweep_set = set(STRESS)
    else:
        sweep_set = set()

    work = root / ".regression_work"
    data_root = work / "runtime"
    if not args.dry_run:
        import shutil
        work.mkdir(exist_ok=True)
        # Re-create the relative readmemh layout without modifying RTL or
        # duplicating committed golden vectors in the published source tree.
        pairs = [
            (data_src,
             data_root / "datasets/golden_fixed/weights_hex"),
            (vectors, data_root / "datasets/golden_fixed/test_vectors_hex"),
        ]
        for source, target in pairs:
            if target.exists():
                shutil.rmtree(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target)

    passed = failed = 0
    started = time.time()
    print(f"RTL       : {rtl_dir}")
    print(f"runtime   : {data_root}")
    print(f"vectors   : {vectors}")
    print(f"tests     : {len(tests)}\n")

    for name in tests:
        test_file = next((tb_dir / (name + ext) for ext in (".sv", ".v")
                          if (tb_dir / (name + ext)).is_file()), None)
        if test_file is None:
            print(f"[FAIL] {name}: no testbench at {tb_dir / (name + '.sv')}")
            failed += 1
            continue

        exe = work / name
        compile_cmd = ["iverilog", "-g2012", "-I", str(rtl_dir), "-s", name,
                       "-o", str(exe), *map(str, sources), str(test_file)]

        if args.dry_run:
            print(f"[DRY RUN] {name}")
            print(f"  compile: {' '.join(compile_cmd)}")
            print(f"  run    : (cwd={data_root}) vvp {exe}")
            continue

        missing = preflight_data(name, test_file, sources, data_root)
        if missing:
            print(f"[FAIL] {name}: {len(missing)} golden file(s) missing under {data_root}")
            for m in missing[:8]:
                print(f"         {m}")
            if len(missing) > 8:
                print(f"         ... and {len(missing) - 8} more")
            failed += 1
            continue

        try:
            c = subprocess.run(compile_cmd, cwd=str(root), capture_output=True,
                               text=True, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f"[FAIL] {name} compile: timed out after {args.timeout}s")
            failed += 1
            continue
        except OSError as exc:
            print(f"[FAIL] {name} compile: {exc}")
            failed += 1
            continue
        offender = scan_output(c.stdout + "\n" + c.stderr)
        if c.returncode != 0 or offender:
            print(f"[FAIL] {name} compile: {offender or 'exit=' + str(c.returncode)}")
            print((c.stderr or c.stdout)[-2000:])
            failed += 1
            continue

        combinations = ([(s, r) for s in seeds for r in stalls]
                        if name in sweep_set else [(None, None)])
        for seed, stall in combinations:
            plusargs = [] if seed is None else [f"+SEED={seed}", f"+STALL_CHANCE={stall}"]
            t0 = time.time()
            ok, details = simulate(["vvp", exe, *plusargs], data_root, args.timeout)
            label = name if seed is None else f"{name} seed={seed} stall={stall}%"
            print(f"[{'PASS' if ok else 'FAIL'}] {label}  ({time.time() - t0:.1f}s)")
            if ok:
                passed += 1
            else:
                failed += 1
                print(details)

    if args.dry_run:
        print("\n[DRY RUN] Nothing was simulated; this is not a verification result.")
        return 0

    print(f"\nSummary: {passed} passed, {failed} failed, "
          f"{time.time() - started:.1f}s total")
    if failed or passed == 0:
        print("[FAIL] Regression did not pass.")
        return 1
    print(f"[PASS] All {passed} runs bit-exact against golden. {SUCCESS_TOKEN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

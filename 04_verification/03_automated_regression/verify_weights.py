#!/usr/bin/env python3
"""Independent re-derivation of the packed parallel-weight ROM mapping.

Conv4, Conv5 and Conv6 do not read their weights as the scalar
``[out_channel][in_channel][kernel]`` arrays the training flow produces. Those
arrays are repacked offline into wide banked ROMs so that `PAR_OUT` output
lanes -- and for Conv6, `K_PAR` kernel taps as well -- can be fetched in a
single cycle. A transposition anywhere in that repack is invisible to every
shape check and produces a design that runs perfectly and computes the wrong
answer.

This script is deliberately **not** a re-run of the repacker. Re-running the
producer and comparing it to itself proves nothing. It works in the direction
the RTL *consumes* the data:

    packed .hex bank files
      -> concatenated exactly as ecg_banked_rom_N wires them
      -> sliced per (lane, kernel-tap) as conv1d_parallel_stream reads them
      -> compared against the scalar [out_channel][in_channel][kernel] file

Three independent checks run per layer:

1. **Shape** -- bank count, word count per bank, hex digits per line, and the
   derived lane count, all cross-checked against the geometry implied by
   ``ecg_params.sv``.
2. **Mapping** -- every (address, lane, tap) slot resolves to the same 16-bit
   word the scalar file holds. This is the byte-for-byte re-derivation.
3. **Conservation** -- the multiset of packed weights equals the multiset of
   scalar weights, so the repack is a pure permutation: nothing duplicated,
   nothing lost, storage unchanged.

The geometry is not hardcoded. Bank wiring, word counts and file names are
parsed out of ``ecg_accel_top.sv`` and the layer dimensions out of
``ecg_params.sv``, so an RTL rewiring or a parameter change cannot pass
silently -- it either changes what is checked or fails the shape check.

    python3 verify_weights.py
    python3 verify_weights.py --layer conv6 --verbose

The address/slot contract being checked is the one `conv1d_parallel_stream`
implements and `tb_conv1d_parallel_golden.sv` independently reproduces:

    TERMS       = IN_CH * K
    K_GROUPS    = K / K_PAR
    ISSUE_TERMS = IN_CH * K_GROUPS
    OUT_GROUPS  = OUT_CH / PAR_OUT

    group = addr // ISSUE_TERMS
    issue = addr %  ISSUE_TERMS
    ic    = issue // K_GROUPS
    kg    = issue %  K_GROUPS

    slot(lane, kp) = lane * K_PAR + kp
    scalar_index   = (group * PAR_OUT + lane) * TERMS + ic * K + kg * K_PAR + kp

and ``ecg_banked_rom_N`` places bank *b* at bits ``[64*b +: 64]``, so FILE0 is
the least significant bank and slot *s* sits at ``16 * (s % lanes_per_bank)``
within bank ``s // lanes_per_bank``.
"""

import argparse
import os
import re
import sys
from collections import Counter

WEIGHT_WIDTH = 16
BANK_WIDTH = 64                       # ecg_banked_rom_N wires 64-bit banks
LANES_PER_BANK = BANK_WIDTH // WEIGHT_WIDTH

LAYERS = ("conv4", "conv5", "conv6")

RTL_SUBPATH = ("03_rtl", "01_CNN_accelerator_IP", "src")
DATA_SUBPATH = ("03_rtl", "02_weight_ROM_reference")

BANKED_ROM_RE = re.compile(
    r"ecg_banked_rom_(\d+)\s*#\s*\((?P<body>.*?)\)\s*\w+\s*\(", re.DOTALL)
SIZE_RE = re.compile(r"\.SIZE\s*\(\s*(\d+)\s*\)")
FILE_RE = re.compile(r"\.FILE(\d+)\s*\(\s*\"([^\"]+)\"\s*\)")
GEOM_RE = re.compile(r"_p(\d+)(?:_k(\d+))?_b\d+\.hex$")


# ---------------------------------------------------------------- RTL parsing

def parse_dims(params_path):
    """Layer dimensions from ecg_params.sv: {'conv4': (in_ch, out_ch, k), ...}."""
    text = open(params_path, encoding="utf-8", errors="replace").read()
    dims = {}
    for layer in LAYERS:
        up = layer.upper()
        got = {}
        for field, suffix in (("in_ch", "IN_CH"), ("out_ch", "OUT_CH"), ("k", "K")):
            m = re.search(rf"\b{up}_{suffix}\s*=\s*(\d+)\s*;", text)
            if m:
                got[field] = int(m.group(1))
        if len(got) == 3:
            dims[layer] = (got["in_ch"], got["out_ch"], got["k"])
    return dims


def parse_banked_roms(top_path):
    """Banked weight ROMs from ecg_accel_top.sv.

    Returns {'conv4': {'banks': [path, ...], 'size': words, 'par_out': n,
                       'k_par': n, 'declared_banks': n}}
    with `banks` ordered FILE0 .. FILEn, i.e. least significant bank first.
    """
    text = open(top_path, encoding="utf-8", errors="replace").read()
    roms = {}
    for m in BANKED_ROM_RE.finditer(text):
        declared = int(m.group(1))
        body = m.group("body")
        size_m = SIZE_RE.search(body)
        files = FILE_RE.findall(body)
        if not size_m or not files:
            continue
        files = [p for _, p in sorted(files, key=lambda kv: int(kv[0]))]
        base = os.path.basename(files[0])
        layer = base.split("_weight", 1)[0]
        if layer not in LAYERS:
            continue
        geom = GEOM_RE.search(base)
        if not geom:
            continue
        roms[layer] = {
            "banks": files,
            "size": int(size_m.group(1)),
            "par_out": int(geom.group(1)),
            "k_par": int(geom.group(2) or 1),
            "declared_banks": declared,
        }
    return roms


# ------------------------------------------------------------------ hex files

def read_scalar(path):
    """Scalar .hex file -> list of 16-bit ints, one per line/token."""
    mask = (1 << WEIGHT_WIDTH) - 1
    words = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.split("//", 1)[0].split("#", 1)[0].strip()
            if not line:
                continue
            for tok in line.split():
                words.append(int(tok, 16) & mask)
    return words


def read_bank(path):
    """Packed bank file -> (list of ints, hex digits per line)."""
    values = []
    digits = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            if digits is None:
                digits = len(line)
            elif len(line) != digits:
                raise ValueError(
                    f"{os.path.basename(path)}:{n}: ragged line width "
                    f"{len(line)} != {digits}")
            values.append(int(line, 16))
    return values, (digits or 0)


# --------------------------------------------------------------------- checks

def check_layer(layer, rom, dims, weights_dir, verbose=False):
    """Run the three checks for one layer. Returns a list of error strings."""
    errors = []
    in_ch, out_ch, k = dims
    par_out, k_par = rom["par_out"], rom["k_par"]

    terms = in_ch * k
    if k % k_par:
        return [f"{layer}: KERNEL_SIZE {k} is not divisible by K_PAR {k_par}"]
    if out_ch % par_out:
        return [f"{layer}: OUT_CHANNELS {out_ch} is not divisible by PAR_OUT {par_out}"]
    k_groups = k // k_par
    issue_terms = in_ch * k_groups
    out_groups = out_ch // par_out
    expected_words = out_groups * issue_terms
    expected_slots = par_out * k_par

    print(f"\n{layer}: IN_CH={in_ch} OUT_CH={out_ch} K={k} "
          f"PAR_OUT={par_out} K_PAR={k_par}")

    # --- check 1: shape ---------------------------------------------------
    banks = rom["banks"]
    if len(banks) != rom["declared_banks"]:
        errors.append(f"{layer}: ecg_banked_rom_{rom['declared_banks']} was given "
                      f"{len(banks)} FILE parameters")
    if len(banks) * LANES_PER_BANK != expected_slots:
        errors.append(f"{layer}: {len(banks)} banks x {LANES_PER_BANK} lanes = "
                      f"{len(banks) * LANES_PER_BANK} slots, but PAR_OUT*K_PAR = "
                      f"{expected_slots}")
    if rom["size"] != expected_words:
        errors.append(f"{layer}: ROM .SIZE({rom['size']}) but OUT_GROUPS*ISSUE_TERMS "
                      f"= {out_groups}*{issue_terms} = {expected_words}")

    bank_data = []
    for b, rel in enumerate(banks):
        path = os.path.join(weights_dir, os.path.basename(rel))
        if not os.path.isfile(path):
            errors.append(f"{layer}: missing bank file {os.path.basename(rel)}")
            return errors
        try:
            values, digits = read_bank(path)
        except ValueError as exc:
            errors.append(f"{layer}: {exc}")
            return errors
        if digits * 4 != BANK_WIDTH:
            errors.append(f"{layer}: bank {b} has {digits} hex digits per line "
                          f"({digits * 4} bits), expected {BANK_WIDTH}")
        if len(values) != expected_words:
            errors.append(f"{layer}: bank {b} has {len(values)} words, "
                          f"expected {expected_words}")
        bank_data.append(values)
    if errors:
        return errors
    print(f"  shape               : {len(banks)} banks x {expected_words} words x "
          f"{LANES_PER_BANK} lanes = {len(banks) * expected_words * LANES_PER_BANK} "
          f"weights OK")

    scalar_path = os.path.join(weights_dir, f"{layer}_weight.hex")
    if not os.path.isfile(scalar_path):
        errors.append(f"{layer}: scalar reference {layer}_weight.hex not found in "
                      f"{weights_dir}")
        return errors
    scalar = read_scalar(scalar_path)
    if len(scalar) != out_ch * terms:
        errors.append(f"{layer}: scalar file holds {len(scalar)} weights, "
                      f"expected OUT_CH*IN_CH*K = {out_ch * terms}")
        return errors

    # --- check 2: lane/tap mapping ----------------------------------------
    compared = 0
    mapping_errors = len(errors)
    for addr in range(expected_words):
        group, issue = divmod(addr, issue_terms)
        ic, kg = divmod(issue, k_groups)
        for lane in range(par_out):
            for kp in range(k_par):
                slot = lane * k_par + kp
                bank, pos = divmod(slot, LANES_PER_BANK)
                got = (bank_data[bank][addr] >> (pos * WEIGHT_WIDTH)) & 0xFFFF
                want = scalar[(group * par_out + lane) * terms
                              + ic * k + kg * k_par + kp]
                compared += 1
                if got != want:
                    errors.append(
                        f"{layer}: addr={addr} lane={lane} tap={kp} "
                        f"(out_ch={group * par_out + lane} in_ch={ic} "
                        f"k={kg * k_par + kp}) packed=0x{got:04x} "
                        f"scalar=0x{want:04x}")
                    if len(errors) > 10:
                        errors.append(f"{layer}: ... further mismatches suppressed")
                        return errors
                elif verbose and compared <= 3:
                    print(f"    addr={addr} lane={lane} tap={kp} -> 0x{got:04x} OK")
    if len(errors) == mapping_errors:
        print(f"  lane/tap mapping    : {compared} (addr,lane,tap) slots re-derived "
              f"and matched OK")
    else:
        print(f"  lane/tap mapping    : {len(errors) - mapping_errors} MISMATCH(ES) "
              f"in {compared} slots compared")

    # --- check 3: conservation --------------------------------------------
    packed = Counter()
    for values in bank_data:
        for word in values:
            for s in range(LANES_PER_BANK):
                packed[(word >> (s * WEIGHT_WIDTH)) & 0xFFFF] += 1
    if packed != Counter(scalar):
        errors.append(f"{layer}: packed weights are not a permutation of the scalar "
                      f"weights (packed {sum(packed.values())}, "
                      f"scalar {len(scalar)})")
    else:
        print(f"  conservation        : {sum(packed.values())} weights, "
              f"exact permutation of the scalar set OK")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project-root", default=None,
                    help="Repository root (default: two levels above this script)")
    ap.add_argument("--layer", action="append", choices=LAYERS,
                    help="Check only this layer; repeatable")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(args.project_root or os.path.join(script_dir, "..", ".."))
    rtl_dir = os.path.join(root, *RTL_SUBPATH)
    weights_dir = os.path.join(root, *DATA_SUBPATH)
    top_path = os.path.join(rtl_dir, "ecg_accel_top.sv")
    params_path = os.path.join(rtl_dir, "ecg_params.sv")

    print("=" * 74)
    print("  Independent re-derivation of the packed parallel weight mapping")
    print("=" * 74)
    print(f"  RTL     : {rtl_dir}")
    print(f"  weights : {weights_dir}")

    for label, path in (("ecg_accel_top.sv", top_path),
                        ("ecg_params.sv", params_path)):
        if not os.path.isfile(path):
            print(f"\n[ERROR] {label} not found at {path}")
            print("[FAIL] Cannot verify the mapping without the RTL. [FAIL]")
            return 1
    if not os.path.isdir(weights_dir):
        print(f"\n[ERROR] weight directory not found: {weights_dir}")
        print("[FAIL] Cannot verify the mapping without the ROM files.")
        return 1

    dims = parse_dims(params_path)
    roms = parse_banked_roms(top_path)

    layers = args.layer or list(LAYERS)
    all_errors = []
    checked = 0
    for layer in layers:
        if layer not in dims:
            all_errors.append(f"{layer}: dimensions not found in ecg_params.sv")
            continue
        if layer not in roms:
            all_errors.append(f"{layer}: no ecg_banked_rom_N instance found in "
                              f"ecg_accel_top.sv")
            continue
        all_errors += check_layer(layer, roms[layer], dims[layer], weights_dir,
                                  args.verbose)
        checked += 1

    print("\n" + "=" * 74)
    if all_errors:
        for e in all_errors:
            print(f"[ERROR] {e}")
        print(f"[FAIL] Packed weight mapping does not match the contract "
              f"({len(all_errors)} error(s)).")
        return 1
    if not checked:
        print("[FAIL] No layers were checked.")
        return 1
    total = sum(dims[l][0] * dims[l][1] * dims[l][2] for l in layers if l in dims)
    print(f"[PASS] {checked} layer(s) re-derived byte-for-byte; {total} weights "
          f"conserved. [SUCCESS]")
    return 0


if __name__ == "__main__":
    sys.exit(main())

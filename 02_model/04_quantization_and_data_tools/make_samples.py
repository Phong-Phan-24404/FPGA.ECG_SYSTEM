#!/usr/bin/env python3
"""
make_samples -- turn MIT-BIH rows into samples for app3 and for the RTL host.

    python make_samples.py --list-classes
    python make_samples.py --verify
    python make_samples.py --mode first-per-class --out-app3 ../app3/data
    python make_samples.py --rows 0,18118,18674 --out-rtl ../app3/rtl_host/vectors

Two different artefacts come out of one row of the CSV:

  app3  data/sample<CODE>.txt   187 float lines, the raw normalised amplitudes.
        app3 quantises at the boundary of whichever backend is selected, so the
        file it reads stays in float.

  RTL   vectors/sample_<i>/input.hex    187 lines of Q8.8, one 16-bit word each
        vectors/sample_<i>/logits.hex   5 lines, the golden fixed-point logits
        vectors/sample_<i>/label.txt    the true class index

Quantisation is deliberately NOT built into app3. Keeping it here means the
golden vectors are produced once, by the same arithmetic the RTL implements,
and can be checked in and diffed -- rather than being recomputed at run time by
code that would have to be kept in step with the hardware.

The MIT-BIH Kaggle CSVs have 188 columns: 187 amplitude samples already
normalised to [0, 1], then the class label 0..4 = N, S, V, F, Q.
"""
from __future__ import annotations

import argparse
import csv
import os
import sys

import numpy as np

from ecg_fixed import (
    ACT_FRAC, CLASS_CODES, CLASS_NAMES, N_CLASSES, N_INPUTS,
    FixedECG1DCNN, to_fixed, to_float, write_hex,
)

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CSV = os.path.join(HERE, "..", "..", "FPGA_CNN", "kaggle", "input", "mitbih_test.csv")
DEFAULT_WEIGHTS = os.path.join(HERE, "..", "..", "06_software", "02_Qt_ECG_application", "python", "weights",
                               "ecg1dcnn_weights_float32.npz")
DEFAULT_APP3_DATA = os.path.join(HERE, "..", "..", "06_software", "02_Qt_ECG_application", "data")
DEFAULT_RTL_VECTORS = os.path.join(HERE, "..", "..", "06_software", "02_Qt_ECG_application", "01_RTL_host_backend", "01_golden_board_test_vectors")
# The shipped RTL vectors were not picked one-per-class: they are the first five
# entries of the golden set, which happen to all be class N. This file records
# which CSV row each one came from.
DEFAULT_GOLDEN_INDICES = os.path.join(HERE, "..", "..", "FPGA_CNN", "datasets",
                                      "golden_float", "golden_indices.csv")


def golden_rows(path: str, count: int = 5):
    """Row indices of the first `count` golden samples, or None if unavailable."""
    if not os.path.exists(path):
        return None
    rows = []
    with open(path, newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or "test_sample_index" not in reader.fieldnames:
            return None
        for record in reader:
            rows.append(int(record["test_sample_index"]))
            if len(rows) == count:
                break
    return rows or None


# ------------------------------------------------------------------ csv ----
def load_rows(csv_path: str, wanted=None):
    """Stream the CSV and return {row_index: (samples 187 float64, label int)}.

    The train CSV is 400 MB, so rows are collected in one pass rather than
    loading the whole file.
    """
    if not os.path.exists(csv_path):
        sys.exit("CSV not found: %s" % csv_path)

    wanted_set = None if wanted is None else set(wanted)
    out = {}
    with open(csv_path) as handle:
        for index, line in enumerate(handle):
            if wanted_set is not None:
                if index not in wanted_set:
                    continue
                if len(out) == len(wanted_set):
                    break
            parts = line.rstrip("\n").split(",")
            if len(parts) != N_INPUTS + 1:
                sys.exit("row %d has %d columns, expected %d"
                         % (index, len(parts), N_INPUTS + 1))
            out[index] = (np.asarray(parts[:N_INPUTS], dtype=np.float64),
                          int(float(parts[N_INPUTS])))
            if wanted_set is not None and len(out) == len(wanted_set):
                break
    if wanted_set is not None:
        missing = sorted(wanted_set - set(out))
        if missing:
            sys.exit("rows not present in the CSV: %s" % missing)
    return out


def first_row_per_class(csv_path: str):
    """The first occurrence of each class, which is how app3's samples were picked."""
    found = {}
    with open(csv_path) as handle:
        for index, line in enumerate(handle):
            label = int(float(line.rstrip("\n").rsplit(",", 1)[1]))
            if label not in found:
                found[label] = index
                if len(found) == N_CLASSES:
                    break
    missing = [c for c in range(N_CLASSES) if c not in found]
    if missing:
        sys.exit("classes absent from the CSV: %s" % missing)
    return [found[c] for c in range(N_CLASSES)]


# ---------------------------------------------------------------- write ----
def write_app3_sample(out_dir: str, code: str, samples: np.ndarray,
                      fmt: str = "q88") -> str:
    """Write app3's data/sample<CODE>.txt.

    fmt="q88"   187 lines of signed Q8.8 integers -- what app3 reads now. The
                beats arrive already quantised, so no interface inside app3 has
                to quantise, and every engine starts from the exact same bits
                the RTL will see.
    fmt="float" 187 lines of %.18e -- the older format, kept so the original
                files can still be reproduced for comparison.
    """
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "sample%s.txt" % code)
    with open(path, "w", newline="\n") as handle:
        if fmt == "q88":
            for value in to_fixed(samples, ACT_FRAC).reshape(-1):
                handle.write("%d\n" % int(value))
        else:
            for value in samples:
                handle.write("%.18e\n" % value)
    return path


def write_rtl_sample(out_dir: str, index: int, samples: np.ndarray, label: int,
                     model: "FixedECG1DCNN | None") -> str:
    sample_dir = os.path.join(out_dir, "sample_%d" % index)
    os.makedirs(sample_dir, exist_ok=True)

    write_hex(os.path.join(sample_dir, "input.hex"), to_fixed(samples, ACT_FRAC))
    with open(os.path.join(sample_dir, "label.txt"), "w", newline="\n") as handle:
        handle.write("%d\n" % label)

    if model is not None:
        logits, _ = model.forward_int(samples)
        write_hex(os.path.join(sample_dir, "logits.hex"), logits)
    return sample_dir


# --------------------------------------------------------------- verify ----
def verify(csv_path: str, weights: str, app3_data: str, rtl_vectors: str) -> int:
    """Regenerate the shipped samples and prove this tool reproduces them exactly.

    Without this the tool would only be plausible; with it, a change in the
    quantisation that silently diverged from the RTL would be caught here.
    """
    rows = first_row_per_class(csv_path)
    print("first row per class in %s:" % os.path.basename(csv_path))
    for class_index, row in enumerate(rows):
        print("  %s -> row %d" % (CLASS_CODES[class_index], row))

    data = load_rows(csv_path, rows)
    failures = 0

    print("\napp3 data/sample<CODE>.txt")
    for class_index, row in enumerate(rows):
        samples, _ = data[row]
        code = CLASS_CODES[class_index]
        reference = os.path.join(app3_data, "sample%s.txt" % code)
        if not os.path.exists(reference):
            print("  %s  SKIP (no reference file)" % code)
            continue
        existing = np.loadtxt(reference)
        # Detect the format from the data rather than a flag: Q8.8 files hold
        # integers up to 256, the float format holds values within [0, 1].
        looks_q88 = bool(np.all(existing == np.round(existing))) and existing.max() > 1.5
        if looks_q88:
            expected = to_fixed(samples, ACT_FRAC).reshape(-1).astype(np.float64)
            label_fmt = "Q8.8"
        else:
            expected = samples
            label_fmt = "float"
        same = existing.shape == expected.shape and np.array_equal(existing, expected)
        print("  %s  %-5s %s" % (code, label_fmt, "MATCH" if same else "DIFFERS"))
        failures += 0 if same else 1

    if not os.path.exists(weights):
        print("\nRTL vectors: SKIP (weights not found at %s)" % weights)
        return 1 if failures else 0

    # The shipped RTL vectors were NOT picked one per class: they are the first
    # five entries of the golden set, which all happen to be class N. Checking
    # them against first-per-class rows would report a mismatch that is really
    # just the wrong reference.
    rtl_rows = golden_rows(os.path.abspath(DEFAULT_GOLDEN_INDICES))
    if rtl_rows is None:
        print("\nRTL vectors: SKIP (golden_indices.csv not available)")
        return 1 if failures else 0
    rtl_data = load_rows(csv_path, rtl_rows)

    model = FixedECG1DCNN(weights)
    print("\nRTL vectors/sample_<i>   (golden rows %s)"
          % ", ".join(str(r) for r in rtl_rows))
    for index, row in enumerate(rtl_rows):
        samples, label = rtl_data[row]
        reference = os.path.join(rtl_vectors, "sample_%d" % index)
        if not os.path.isdir(reference):
            print("  sample_%d  SKIP (no reference dir)" % index)
            continue

        expected_input = to_fixed(samples, ACT_FRAC).reshape(-1)
        got_input = np.loadtxt(os.path.join(reference, "input.hex"),
                               dtype=np.int64, converters={0: lambda s: int(s, 16)})
        got_input = np.asarray(got_input, dtype=np.int64).reshape(-1)
        got_input = np.where(got_input >= 0x8000, got_input - 0x10000, got_input)
        input_ok = np.array_equal(expected_input, got_input)

        logits, _ = model.forward_int(samples)
        logits_path = os.path.join(reference, "logits.hex")
        if os.path.exists(logits_path):
            got_logits = np.loadtxt(logits_path, dtype=np.int64,
                                    converters={0: lambda s: int(s, 16)})
            got_logits = np.asarray(got_logits, dtype=np.int64).reshape(-1)
            got_logits = np.where(got_logits >= 0x8000, got_logits - 0x10000, got_logits)
            logits_ok = np.array_equal(logits, got_logits)
        else:
            logits_ok = None

        print("  sample_%d  input.hex %-7s logits.hex %s"
              % (index,
                 "MATCH" if input_ok else "DIFFERS",
                 "MATCH" if logits_ok else ("n/a" if logits_ok is None else "DIFFERS")))
        failures += 0 if input_ok else 1
        failures += 0 if logits_ok is not False else 1

    print("\nRESULT: %s" % ("ALL MATCH" if failures == 0 else "%d mismatch(es)" % failures))
    return 1 if failures else 0


# ------------------------------------------------------------------ main ----
def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", default=DEFAULT_CSV,
                        help="MIT-BIH CSV (default: mitbih_test.csv)")
    parser.add_argument("--weights", default=DEFAULT_WEIGHTS,
                        help="FP32 .npz, quantised to Q2.14 to produce golden logits")
    parser.add_argument("--mode", choices=["first-per-class", "golden"],
                        default="first-per-class",
                        help="how to pick rows when --rows is not given: one beat "
                             "per class (app3's five demo beats), or the rows the "
                             "shipped RTL golden vectors came from")
    parser.add_argument("--rows", help="explicit comma-separated row indices")
    parser.add_argument("--out-app3", nargs="?", const=DEFAULT_APP3_DATA,
                        help="write sample<CODE>.txt here (default: app3/data)")
    parser.add_argument("--out-rtl", nargs="?", const=DEFAULT_RTL_VECTORS,
                        help="write sample_<i>/ here (default: app3/rtl_host/vectors)")
    parser.add_argument("--app3-format", choices=["q88", "float"], default="q88",
                        help="format for data/sample<CODE>.txt: q88 (default, what "
                             "app3 reads now) or float (the original format)")
    parser.add_argument("--no-logits", action="store_true",
                        help="skip golden logits (no weights needed)")
    parser.add_argument("--list-classes", action="store_true",
                        help="print the first row index of each class and exit")
    parser.add_argument("--verify", action="store_true",
                        help="regenerate the shipped samples and compare")
    args = parser.parse_args()

    csv_path = os.path.abspath(args.csv)

    if args.list_classes:
        for class_index, row in enumerate(first_row_per_class(csv_path)):
            print("%s  %-26s first row %d"
                  % (CLASS_CODES[class_index], CLASS_NAMES[CLASS_CODES[class_index]], row))
        return 0

    if args.verify:
        return verify(csv_path, os.path.abspath(args.weights),
                      os.path.abspath(DEFAULT_APP3_DATA),
                      os.path.abspath(DEFAULT_RTL_VECTORS))

    if not args.out_app3 and not args.out_rtl:
        parser.error("nothing to do: pass --out-app3 and/or --out-rtl")

    if args.rows:
        rows = [int(token) for token in args.rows.split(",") if token.strip()]
    elif args.mode == "golden":
        rows = golden_rows(os.path.abspath(DEFAULT_GOLDEN_INDICES))
        if rows is None:
            sys.exit("golden_indices.csv not available; use --rows or --mode first-per-class")
    else:
        rows = first_row_per_class(csv_path)

    data = load_rows(csv_path, rows)

    model = None
    if args.out_rtl and not args.no_logits:
        if not os.path.exists(args.weights):
            sys.exit("weights not found: %s (use --no-logits to skip golden logits)"
                     % args.weights)
        model = FixedECG1DCNN(os.path.abspath(args.weights))

    for index, row in enumerate(rows):
        samples, label = data[row]

        if args.out_app3:
            # app3 keys its five demo beats by class code, so a row's own label
            # decides the filename; writing by position would mislabel any
            # selection that is not one-per-class in order.
            if not 0 <= label < N_CLASSES:
                sys.exit("row %d has label %d, outside 0..%d" % (row, label, N_CLASSES - 1))
            path = write_app3_sample(os.path.abspath(args.out_app3),
                                     CLASS_CODES[label], samples, args.app3_format)
            print("row %-6d -> %s" % (row, path))

        if args.out_rtl:
            sample_dir = write_rtl_sample(os.path.abspath(args.out_rtl), index,
                                          samples, label, model)
            extra = ""
            if model is not None:
                logits, _ = model.forward_int(samples)
                extra = "  logits=%s  argmax=%s" % (
                    " ".join("%+.3f" % v for v in to_float(logits, ACT_FRAC)),
                    CLASS_CODES[int(np.argmax(logits))])
            print("row %-6d -> %s  label=%s%s"
                  % (row, sample_dir, CLASS_CODES[label], extra))

    return 0


if __name__ == "__main__":
    sys.exit(main())

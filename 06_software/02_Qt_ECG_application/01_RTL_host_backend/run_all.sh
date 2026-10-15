#!/bin/bash
# run_all.sh -- load the coherent-buffer module and run every golden sample.
#
#   sudo ./run_all.sh
#
# Re-inserting the module each time is deliberate: it re-allocates the buffer,
# so a run never inherits state from a previous one.
set -u
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (needs /dev/mem)" >&2
    exit 1
fi

if [ ! -e /sys/module/pl_dmabuf ]; then
    insmod ./pl_dmabuf.ko || { echo "insmod failed" >&2; exit 1; }
fi
printf 'coherent buffer at phys 0x%08x\n\n' \
       "$(cat /sys/module/pl_dmabuf/parameters/phys_addr)"

pass=0; fail=0
for s in 0 1 2 3 4; do
    d=01_golden_board_test_vectors/sample_$s
    [ -d "$d" ] || continue
    echo "================ sample_$s ================"
    if ./cnn_run "$d/input.hex" "$d/logits.hex" "$(cat "$d/label.txt")"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
    echo
done
echo "samples bit-exact vs golden: $pass   differing: $fail"

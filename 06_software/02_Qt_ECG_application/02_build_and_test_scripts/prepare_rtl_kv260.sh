#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL_DIR="${ROOT_DIR}/01_RTL_host_backend"
KDIR="/lib/modules/$(uname -r)/build"

ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" && "${ARCH}" != "arm64" ]]; then
  echo "[ERROR] RTL PL host setup is intended for the AArch64 Kria KV260; current architecture: ${ARCH}"
  exit 1
fi

if [[ ! -d "${KDIR}" ]]; then
  echo "[ERROR] Kernel build directory not found: ${KDIR}"
  echo "Install the matching kernel headers/build tree for the KV260 image, then rerun this script."
  exit 1
fi

make -C "${RTL_DIR}" clean
make -C "${RTL_DIR}" module cnn_run

if lsmod | awk '{print $1}' | grep -qx pl_dmabuf; then
  sudo rmmod pl_dmabuf
fi
sudo insmod "${RTL_DIR}/pl_dmabuf.ko"

if [[ ! -r /sys/module/pl_dmabuf/parameters/phys_addr || ! -e /dev/pl_dmabuf ]]; then
  echo "[ERROR] pl_dmabuf did not initialize correctly."
  exit 1
fi

echo "[OK] RTL coherent DMA buffer ready."
echo "     phys_addr=$(cat /sys/module/pl_dmabuf/parameters/phys_addr)"
echo "     device=/dev/pl_dmabuf"
echo "[NEXT] Ensure the verified custom PL bitstream is loaded, then run:"
echo "       ./02_build_and_test_scripts/run_kv260.sh --backend rtl"

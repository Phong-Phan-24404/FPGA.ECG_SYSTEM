#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT_DIR}/build-aarch64-kv260/ECGAIMonitor"
BACKEND="${ECG_BACKEND:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      [[ $# -ge 2 ]] || { echo "[ERROR] --backend requires rtl, cpu, or dpu"; exit 2; }
      BACKEND="${2,,}"
      shift 2
      ;;
    --rtl) BACKEND="rtl"; shift ;;
    --cpu) BACKEND="cpu"; shift ;;
    --dpu) BACKEND="dpu"; shift ;;
    *) echo "[ERROR] Unknown option: $1"; exit 2 ;;
  esac
done

if [[ ! -x "${APP}" ]]; then
  echo "[ERROR] KV260 build not found. Run 02_build_and_test_scripts/build_kv260.sh first."
  exit 1
fi

if [[ -z "${ECG_XMODEL_PATH:-}" ]]; then
  export ECG_XMODEL_PATH="${ROOT_DIR}/models/ecg_1dcnn_2d_dpu.xmodel"
fi

case "${BACKEND}" in
  "") ;;
  rtl|cpu|dpu) export ECG_BACKEND="${BACKEND}" ;;
  *) echo "[ERROR] Backend must be rtl, cpu, or dpu"; exit 2 ;;
esac

if [[ "${BACKEND}" == "rtl" ]]; then
  if [[ ! -e /dev/pl_dmabuf || ! -r /sys/module/pl_dmabuf/parameters/phys_addr ]]; then
    echo "[ERROR] RTL DMA buffer is not ready. Run 02_build_and_test_scripts/prepare_rtl_kv260.sh first."
    exit 1
  fi
  if [[ ${EUID} -ne 0 ]]; then
    echo "[INFO] RTL mode drives AXI registers through /dev/mem and requires root/CAP_SYS_RAWIO."
    echo "[INFO] Re-launching the GUI with sudo -E so DISPLAY/XAUTHORITY are preserved."
    exec sudo -E env \
      ECG_BACKEND=rtl \
      ECG_XMODEL_PATH="${ECG_XMODEL_PATH}" \
      DISPLAY="${DISPLAY:-}" \
      XAUTHORITY="${XAUTHORITY:-}" \
      "${APP}" --backend rtl
  fi
fi

ARGS=()
if [[ -n "${BACKEND}" ]]; then
  ARGS+=(--backend "${BACKEND}")
fi
exec "${APP}" "${ARGS[@]}"

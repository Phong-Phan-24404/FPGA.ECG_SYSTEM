#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-x86_64"

if [[ "${1:-}" == "--install-deps" ]]; then
  sudo apt-get update
  sudo apt-get install -y build-essential cmake qtbase5-dev libqt5printsupport5
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" && "${ARCH}" != "amd64" ]]; then
  echo "[WARN] Expected x86_64/amd64 for WSL build; current architecture: ${ARCH}"
fi

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DECG_ENABLE_VITIS_AI=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" -j"$(nproc)"
"${BUILD_DIR}/ECGAIMonitor" --self-test

echo "[OK] x86_64/WSL build complete: ${BUILD_DIR}/ECGAIMonitor"
echo "     GUI/emulator is fully enabled. WSL uses the transparent CPU template classifier; DPU inference is KV260-only."

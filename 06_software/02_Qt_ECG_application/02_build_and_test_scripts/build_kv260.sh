#!/usr/bin/env bash
# Build ECGAIMonitor natively on the KV260.
#
#   02_build_and_test_scripts/build_kv260.sh [--install-deps] [--vitis-ai auto|on|off]
#
# The Vitis AI (DPU) backend is optional. This board carries the custom PL CNN
# overlay, not a DPU, and has no Vitis AI runtime installed, so the default is
# to detect what is actually present rather than to demand it. The CPU and RTL
# backends do not depend on Vitis AI at all -- see classifierBackendCompiled()
# in src/ai/heartbeat_classifier.cpp, where only ClassifierBackend::Dpu is
# guarded by ECG_ENABLE_VITIS_AI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-aarch64-kv260"
VITIS_AI_MODE="auto"
INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1; shift ;;
    --vitis-ai)     VITIS_AI_MODE="${2:-auto}"; shift 2 ;;
    --vitis-ai=*)   VITIS_AI_MODE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "${VITIS_AI_MODE}" in
  auto|on|off) ;;
  *) echo "--vitis-ai must be auto, on or off (got '${VITIS_AI_MODE}')" >&2; exit 2 ;;
esac

if [[ ${INSTALL_DEPS} -eq 1 ]]; then
  sudo apt-get update
  sudo apt-get install -y build-essential cmake qtbase5-dev libqt5printsupport5
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" && "${ARCH}" != "arm64" ]]; then
  echo "[WARN] This script is intended for native AArch64/KV260; current architecture: ${ARCH}"
fi

# Ask the linker, not ldconfig. ldconfig misses libraries installed outside its
# cache, and a successful link is exactly what CMake's find_library plus
# target_link_libraries will need later.
have_vitis_ai() {
  local cxx=${CXX:-c++}
  echo 'int main(){return 0;}' \
    | "${cxx}" -x c++ - -lvart-runner -lxir -o /dev/null >/dev/null 2>&1
}

if [[ "${VITIS_AI_MODE}" == "auto" ]]; then
  if have_vitis_ai; then
    ENABLE_VITIS_AI=ON
    echo "[INFO] Vitis AI runtime found -- enabling the DPU backend."
  else
    ENABLE_VITIS_AI=OFF
    echo "[INFO] Vitis AI runtime not found -- building CPU + RTL backends only."
    echo "       (Pass --vitis-ai on to require it, once libvart-runner and libxir"
    echo "        are installed and a DPU bitstream is loaded.)"
  fi
elif [[ "${VITIS_AI_MODE}" == "on" ]]; then
  # Fail here with a clear message rather than letting CMake's REQUIRED
  # find_library produce a bare "Could not find VART_RUNNER_LIBRARY".
  if ! have_vitis_ai; then
    echo "[ERROR] --vitis-ai on was requested, but libvart-runner/libxir cannot be linked." >&2
    echo "        Install the KV260 Vitis AI runtime, or use --vitis-ai off/auto." >&2
    exit 1
  fi
  ENABLE_VITIS_AI=ON
else
  ENABLE_VITIS_AI=OFF
fi

# A previous run may have cached a different value, or died mid-configure and
# left an unusable cache. Reconfigure from scratch when the setting changes.
CACHE="${BUILD_DIR}/CMakeCache.txt"
if [[ -f "${CACHE}" ]]; then
  CACHED="$(sed -n 's/^ECG_ENABLE_VITIS_AI:BOOL=//p' "${CACHE}" | head -1)"
  if [[ "${CACHED}" != "${ENABLE_VITIS_AI}" ]]; then
    echo "[INFO] ECG_ENABLE_VITIS_AI changed (${CACHED:-unset} -> ${ENABLE_VITIS_AI}); reconfiguring."
    rm -rf "${BUILD_DIR}"
  fi
fi

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" \
      -DECG_ENABLE_VITIS_AI="${ENABLE_VITIS_AI}" \
      -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" -j"$(nproc)"

# --self-test builds a QCoreApplication, not a QApplication, so it needs no
# display and is safe to run over ssh.
"${BUILD_DIR}/ECGAIMonitor" --self-test

echo "[OK] AArch64/KV260 build complete: ${BUILD_DIR}/ECGAIMonitor"
echo "     DPU backend: ${ENABLE_VITIS_AI}"

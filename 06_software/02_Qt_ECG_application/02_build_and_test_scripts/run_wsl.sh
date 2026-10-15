#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT_DIR}/build-x86_64/ECGAIMonitor"

if [[ ! -x "${APP}" ]]; then
  "${ROOT_DIR}/02_build_and_test_scripts/build_wsl.sh"
fi

# WSLg normally exposes /mnt/wslg/runtime-dir owned by UID 1000.  When this
# distro user has another UID (for example 1001), Qt warns that the runtime
# directory is not owned by the current process.  Use a private runtime
# directory and the WSLg X11/XCB path instead of depending on that Wayland
# runtime directory.
if [[ -n "${WSL_DISTRO_NAME:-}" || -d /mnt/wslg ]]; then
  RUNTIME_DIR="${TMPDIR:-/tmp}/ecg-ai-monitor-runtime-$(id -u)"
  mkdir -p "${RUNTIME_DIR}"
  chmod 700 "${RUNTIME_DIR}"
  export XDG_RUNTIME_DIR="${RUNTIME_DIR}"

  # Qt 5.15 on Ubuntu 22.04 is very stable through WSLg's X11 bridge.
  # Override with ECG_QT_PLATFORM=wayland only when explicitly desired.
  export QT_QPA_PLATFORM="${ECG_QT_PLATFORM:-xcb}"
  export QT_X11_NO_MITSHM=1
fi

if [[ "${QT_QPA_PLATFORM:-}" == "xcb" && -z "${DISPLAY:-}" ]]; then
  echo "[ERROR] DISPLAY is empty, so the WSLg X11 display is unavailable." >&2
  echo "        Restart WSL from Windows with: wsl --shutdown" >&2
  echo "        Then reopen the distro and run this script again." >&2
  exit 1
fi

echo "[INFO] uid=$(id -u) platform=${QT_QPA_PLATFORM:-auto} DISPLAY=${DISPLAY:-<unset>} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
exec "${APP}" "$@"

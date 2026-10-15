#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT_DIR}/ecg_ai_monitor_kv260_source.tar.gz"
tar --exclude='./build-x86_64' --exclude='./build-aarch64-kv260' --exclude='./.git' \
    -czf "${OUT}" -C "${ROOT_DIR}" .
echo "[OK] Created ${OUT}"

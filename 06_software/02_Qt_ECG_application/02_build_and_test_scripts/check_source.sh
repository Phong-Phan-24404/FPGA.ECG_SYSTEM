#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

for script in 02_build_and_test_scripts/*.sh; do
  bash -n "${script}"
done

python3 - <<'PY'
from pathlib import Path
import json, math
root = Path('.')
required = [
    'CMakeLists.txt', 'qcustomplot.cpp', 'qcustomplot.h',
    'src/main.cpp', 'src/fixed_beat_library.cpp', 'src/rhythm_emulator.cpp',
    'src/display_processor.cpp', 'src/signal_buffer.cpp',
    'src/demo_controller.cpp', 'src/demo_window.cpp', 'src/abnormal_review_window.cpp',
    'src/ai/beat_preprocessor.cpp', 'src/ai/heartbeat_classifier.cpp',
    '01_RTL_host_backend/pl_dmabuf.c', '01_RTL_host_backend/cnn_run.c', '01_RTL_host_backend/Makefile',
    'models/ecg_1dcnn_2d_dpu.xmodel', 'models/model_metadata.json',
]
for rel in required:
    assert (root / rel).is_file(), f'missing required file: {rel}'
for code in 'NSVFQ':
    path = root / 'data' / f'sample{code}.txt'
    assert path.is_file(), path
    vals = [float(x) for x in path.read_text().split()]
    assert len(vals) == 187, (path, len(vals))
    assert all(math.isfinite(x) for x in vals)
    assert min(vals) >= 0 and max(vals) <= 256, f"Q8.8 out of range: {path}"
    assert all(x == int(x) for x in vals) and max(vals) > 1, f"not Q8.8: {path}"
meta = json.loads((root / 'models/model_metadata.json').read_text())
assert meta['input_shape'] == [1, 187, 1]
cmake = (root / 'CMakeLists.txt').read_text()
assert 'SerialPort' not in cmake
assert 'ECG_ENABLE_VITIS_AI' in cmake
assert 'ECGAIMonitor' in cmake

review = (root / 'src' / 'abnormal_review_window.cpp').read_text()
controller = (root / 'src' / 'demo_controller.cpp').read_text()
buffer_header = (root / 'src' / 'signal_buffer.h').read_text()
assert 'Three-beat context' in review
assert 'BEFORE' in review and 'SELECTED' in review and 'AFTER' in review
assert 'extractRange' in buffer_header
assert 'reportedBeat.displayWave' not in controller
assert 'finalizeContextCaptures' in controller

demo_window = (root / 'src' / 'demo_window.cpp').read_text()
display_processor = (root / 'src' / 'display_processor.cpp').read_text()
for preset in ['0.7–40 Hz', '1–35 Hz', '5–25 Hz']:
    assert preset in demo_window, f'missing main-view clinical preset: {preset}'
    assert preset in review, f'missing review-view clinical preset: {preset}'
    assert preset not in display_processor, f'clinical UI preset leaked into display processing: {preset}'
assert 'setCurrentIndex(1)' in demo_window
assert 'setCurrentIndex(1)' in review
assert 'displayFilterCombo_' not in controller

classifier = (root / 'src' / 'ai' / 'heartbeat_classifier.cpp').read_text()
classifier_h = (root / 'src' / 'ai' / 'heartbeat_classifier.h').read_text()
for backend in ['ClassifierBackend::Rtl', 'ClassifierBackend::Cpu', 'ClassifierBackend::Dpu']:
    assert backend in classifier, f'missing backend implementation: {backend}'
assert 'RtlPlHeartbeatClassifier' in classifier
assert 'CPU FP32 CNN (Python/NumPy)' in classifier
assert 'Vitis AI DPU' in classifier
assert 'enum class ClassifierBackend' in classifier_h
assert '/dev/pl_dmabuf' in classifier and '/dev/mem' in classifier
assert '0x80010000' in classifier and '0x80020000' in classifier

assert (root / '02_build_and_test_scripts' / 'prepare_rtl_kv260.sh').is_file()
run_kv = (root / '02_build_and_test_scripts' / 'run_kv260.sh').read_text()
assert '--backend' in run_kv and 'rtl' in run_kv and 'cpu' in run_kv and 'dpu' in run_kv

for stale in ['demo_dataset.cpp', 'realtime_controller.cpp', 'sources.cpp', 'strategies.cpp']:
    assert not any(p.name == stale for p in root.rglob('*')), f'stale source remains: {stale}'
print('[OK] source/layout/data checks passed')
PY

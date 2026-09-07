#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYINSTALLER_CONFIG_DIR="$PWD/.runtime/pyinstaller-cache"
.venv/bin/python -m PyInstaller --noconfirm --clean --onedir \
  --name HushWorker --paths backend \
  --distpath .runtime/packaged --workpath .runtime/pyinstaller-build \
  --specpath .runtime \
  --collect-all kokoro_onnx --collect-all espeakng_loader \
  --collect-all phonemizer --collect-all onnxruntime \
  --copy-metadata kokoro-onnx \
  backend/worker_entry.py

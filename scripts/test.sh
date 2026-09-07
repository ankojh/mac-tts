#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH="$PWD/backend"
export HUSH_MODEL_DIR="${HUSH_MODEL_DIR:-$PWD/.runtime/models}"
.venv/bin/python -m unittest discover -s backend/tests -v
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift test --disable-sandbox --scratch-path "$PWD/.build"
if [[ "${1:-}" == "--audio" ]]; then .venv/bin/python scripts/benchmark.py; fi

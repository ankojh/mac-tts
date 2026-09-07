#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${HUSH_PYTHON:-}" ]]; then
  python_bin="$HUSH_PYTHON"
else
  python_bin=""
  for candidate in python3.12 python3.13 python3.11; do
    if command -v "$candidate" >/dev/null 2>&1; then
      python_bin="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$python_bin" ]]; then
  echo "Python 3.11–3.13 is required. Install Python 3.12, then rerun this script."
  exit 1
fi
"$python_bin" -c 'import sys; assert (3, 11) <= sys.version_info[:2] < (3, 14), "Use Python 3.11–3.13"'
if [[ ! -x .venv/bin/python ]]; then "$python_bin" -m venv .venv; fi
.venv/bin/python -m pip install -r backend/requirements.lock
export PYTHONPATH="$PWD/backend"
export HUSH_MODEL_DIR="${HUSH_MODEL_DIR:-$PWD/.runtime/models}"
.venv/bin/python -u -m hush_tts.models
echo "Ready. Run ./scripts/build.sh, then open dist/Hush.app."

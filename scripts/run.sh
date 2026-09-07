#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Hush.app ]]; then
  open /Applications/Hush.app
  exit 0
fi
if [[ ! -x .venv/bin/python ]]; then ./scripts/setup.sh; fi
if [[ ! -d dist/Hush.app ]]; then ./scripts/build.sh; fi
open dist/Hush.app

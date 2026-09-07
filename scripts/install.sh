#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export HUSH_STANDALONE=1
./scripts/package-worker.sh
./scripts/build.sh
install_root="${HUSH_INSTALL_DIR:-/Applications}"
mkdir -p "$install_root"
ditto dist/Hush.app "$install_root/Hush.app"
codesign --verify --deep --strict "$install_root/Hush.app"
echo "Installed $install_root/Hush.app"

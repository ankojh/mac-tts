#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --disable-sandbox --scratch-path "$PWD/.build"
binary_dir="$(swift build -c release --disable-sandbox --scratch-path "$PWD/.build" --show-bin-path)"
app_dir="$PWD/.runtime/app-staging/Hush.app"
# Always stage a fresh bundle; a development build must not retain a stale
# frozen worker from an earlier standalone build.
.venv/bin/python -c 'import shutil; shutil.rmtree(".runtime/app-staging", ignore_errors=True)'
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/backend"
cp "$binary_dir/Hush" "$app_dir/Contents/MacOS/Hush"
rsync -a --delete --exclude '__pycache__' backend/hush_tts/ "$app_dir/Contents/Resources/backend/hush_tts/"
export HUSH_BUILD_ROOT="$PWD"
export HUSH_BUILD_APP="$app_dir"
export HUSH_MODEL_DIR="${HUSH_MODEL_DIR:-$PWD/.runtime/models}"
swift scripts/make-icon.swift "$PWD/.runtime/Hush.iconset"
iconutil -c icns "$PWD/.runtime/Hush.iconset" -o "$app_dir/Contents/Resources/Hush.icns"
if [[ "${HUSH_STANDALONE:-0}" == "1" ]]; then
  if [[ ! -x .runtime/packaged/HushWorker/HushWorker ]]; then ./scripts/package-worker.sh; fi
  mkdir -p "$app_dir/Contents/Resources/worker" "$app_dir/Contents/Resources/models"
  rsync -a --delete .runtime/packaged/HushWorker/ "$app_dir/Contents/Resources/worker/"
  cp "$HUSH_MODEL_DIR/kokoro-v1.0.int8.onnx" "$HUSH_MODEL_DIR/voices-v1.0.bin" "$app_dir/Contents/Resources/models/"
fi
/usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path
root = Path(os.environ['HUSH_BUILD_ROOT'])
app = Path(os.environ['HUSH_BUILD_APP'])
info = {
    'CFBundleName': 'Hush',
    'CFBundleDisplayName': 'Hush',
    'CFBundleExecutable': 'Hush',
    'CFBundleIdentifier': 'local.hush.reader',
    'CFBundleVersion': '7',
    'CFBundleShortVersionString': '0.6.1',
    'CFBundlePackageType': 'APPL',
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': False,
    'CFBundleIconFile': 'Hush',
    'NSHighResolutionCapable': True,
    'NSAccessibilityUsageDescription': 'Hush reads the text you select and highlights the sentence and word being spoken.',
    'HushPython': str(root / '.venv/bin/python'),
    'HushModelDirectory': os.environ['HUSH_MODEL_DIR'],
}
if os.environ.get('HUSH_STANDALONE') == '1':
    info.pop('HushPython')
    info.pop('HushModelDirectory')
with (app / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
PY
if [[ -n "${HUSH_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$HUSH_SIGNING_IDENTITY" "$app_dir"
elif [[ "${HUSH_USE_LOCAL_SIGNING:-0}" == "1" && -f .runtime/signing/identity.json ]]; then
  .venv/bin/python scripts/local-signing.py "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
  echo "Development signature: after code changes, remove and re-add Hush in Accessibility settings."
  echo "For a stable identity across builds, set HUSH_SIGNING_IDENTITY to your code-signing certificate."
fi
codesign --verify --deep --strict "$app_dir"
mkdir -p "$PWD/dist/Hush.app"
rsync -a --delete "$app_dir/" "$PWD/dist/Hush.app/"
codesign --verify --deep --strict "$PWD/dist/Hush.app"
echo "Built $PWD/dist/Hush.app"

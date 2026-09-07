"""Explicit, checksum-verified first-run download. No network during synthesis."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import urllib.request

BASE_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/"
ASSETS = {
    "kokoro-v1.0.int8.onnx": "ae315a79b623f244700e4afb9246c46a26066782e049ba174bf3ba433970ee9c",
    "voices-v1.0.bin": "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
}


def model_dir() -> Path:
    return Path(os.environ.get("HUSH_MODEL_DIR", Path.home() / "Library/Application Support/Hush/models"))


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def ready() -> bool:
    return all((model_dir() / name).is_file() for name in ASSETS)


def download(progress=lambda message: None):
    root = model_dir()
    root.mkdir(parents=True, exist_ok=True)
    for name, expected in ASSETS.items():
        target = root / name
        if target.exists() and digest(target) == expected:
            progress(f"Verified {name}")
            continue
        temporary = target.with_suffix(target.suffix + ".part")
        try:
            progress(f"Downloading {name}")
            request = urllib.request.Request(BASE_URL + name, headers={"User-Agent": "Hush/0.1"})
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
                total = int(response.headers.get("Content-Length", 0))
                received = 0
                next_report = 0
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    received += len(chunk)
                    if received >= next_report:
                        progress(f"{name}: {received // 1_000_000} / {total // 1_000_000} MB")
                        next_report = received + 10_000_000
            if digest(temporary) != expected:
                raise RuntimeError(f"Checksum mismatch for {name}. Please retry setup.")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    progress("Local voices are ready")


if __name__ == "__main__":
    download(print)

"""Check a packaged worker from /tmp without Python or project import paths."""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import wave

root = Path(__file__).resolve().parents[1]
worker = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / ".runtime/packaged/HushWorker/HushWorker"
models = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else root / ".runtime/models"
env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "HUSH_MODEL_DIR": str(models), "HF_HUB_OFFLINE": "1"}
process = subprocess.Popen([str(worker)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, cwd="/private/tmp", env=env)
try:
    operations = [{"id": "status", "op": "status"},
                  {"id": "prepare", "op": "prepare", "text": "# Local reading\n- First item.\n- Second item."}]
    for voice in ["af_heart", "af_bella", "af_nicole", "am_michael", "bf_emma", "bm_george"]:
        operations.append({"id": voice, "op": "synthesize", "text": "Hush is installed on this Mac and ready to read.", "voice": voice})
    stdout, _ = process.communicate("\n".join(json.dumps(op) for op in operations) + "\n", timeout=120)
    assert process.returncode == 0, f"Worker exited with {process.returncode}"
    replies = [json.loads(line) for line in stdout.splitlines()]
    assert len(replies) == len(operations), "Missing worker replies"
    for reply in replies:
        assert reply["ok"], reply
        if "audio" in reply["result"]:
            result = reply["result"]
            with wave.open(io.BytesIO(base64.b64decode(result["audio"]))) as wav:
                assert wav.getframerate() == 24000 and wav.getnframes() > 24000
            words = result["words"]
            assert len(words) >= 8, f"Insufficient word alignment: {words}"
            assert all(0 <= w["start"] < w["end"] <= result["duration"] + 0.001 for w in words)
            assert all(a["index"] < b["index"] and a["end"] <= b["start"] + 0.001 for a, b in zip(words, words[1:]))
            print(f"{reply['id']}: {result['duration']:.2f}s of audio in {result['elapsed']:.2f}s", flush=True)
    assert replies[0]["result"]["ready"]
    assert len(replies[1]["result"]["segments"]) == 3
    print("Standalone worker passed: no system Python, project imports, or external model paths required beyond the supplied bundle model directory.")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()

"""Real inference smoke test for all voices. Does not play sound or save speech."""
import base64
import io
import json
import platform
import resource
import time
import wave

from hush_tts.engine import Engine, VOICES

engine = Engine()
started = time.monotonic()
engine.load()
load_seconds = time.monotonic() - started
results = []
for voice in VOICES:
    result = engine.synthesize("A quieter way to read. Your words stay on this Mac, so you can listen at your own pace.", voice["id"])
    with wave.open(io.BytesIO(base64.b64decode(result["audio"]))) as audio:
        assert audio.getnchannels() == 1
        assert audio.getframerate() == 24000
        assert audio.getnframes() > 24000
    results.append({"voice": voice["id"], "audio_seconds": round(result["duration"], 3),
                    "synthesis_seconds": round(result["elapsed"], 3),
                    "realtime_factor": round(result["elapsed"] / result["duration"], 3)})
print(json.dumps({"architecture": platform.machine(), "model_load_seconds": round(load_seconds, 3),
                  "peak_memory_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1_000_000),
                  "results": results}, indent=2))

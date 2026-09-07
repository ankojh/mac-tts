from __future__ import annotations

import base64
import io
import time
import wave

from .models import ASSETS, digest, model_dir, ready
from .alignment import align_words

VOICES = [
    {"id": "af_heart", "name": "Heart", "detail": "American · warm", "lang": "en-us"},
    {"id": "af_bella", "name": "Bella", "detail": "American · bright", "lang": "en-us"},
    {"id": "af_nicole", "name": "Nicole", "detail": "American · soft", "lang": "en-us"},
    {"id": "am_michael", "name": "Michael", "detail": "American · deep", "lang": "en-us"},
    {"id": "bf_emma", "name": "Emma", "detail": "British · clear", "lang": "en-gb"},
    {"id": "bm_george", "name": "George", "detail": "British · steady", "lang": "en-gb"},
]


class Engine:
    def __init__(self):
        self.model = None

    def load(self):
        if self.model is not None:
            return
        if not ready():
            raise RuntimeError("Local model is missing. Run scripts/setup.sh first.")
        for name, expected in ASSETS.items():
            if digest(model_dir() / name) != expected:
                raise RuntimeError("Local model verification failed. Run scripts/setup.sh to repair it.")
        import onnxruntime as ort
        ort.disable_telemetry_events()
        from kokoro_onnx import Kokoro
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        session = ort.InferenceSession(str(model_dir() / "kokoro-v1.0.int8.onnx"),
                                       sess_options=options, providers=["CPUExecutionProvider"])
        self.model = Kokoro.from_session(session, str(model_dir() / "voices-v1.0.bin"))

    def synthesize(self, text: str, voice_id: str) -> dict:
        if not isinstance(text, str) or not text.strip() or len(text) > 500:
            raise ValueError("Speech chunks must contain 1–500 characters.")
        voice = next((v for v in VOICES if v["id"] == voice_id), None)
        if voice is None:
            raise ValueError("Choose one of the available voices.")
        started = time.monotonic()
        self.load()
        import numpy as np
        samples, rate, timings = self.model.create_timed(text, voice=voice_id, speed=1.0, lang=voice["lang"])
        words = align_words(text, timings, self.model.tokenizer, voice["lang"])
        if not len(samples) or not np.isfinite(samples).all():
            raise RuntimeError("The model returned invalid audio. Try another voice.")
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(pcm)
        return {"audio": base64.b64encode(output.getvalue()).decode("ascii"),
                "duration": len(samples) / rate, "words": words,
                "elapsed": time.monotonic() - started}

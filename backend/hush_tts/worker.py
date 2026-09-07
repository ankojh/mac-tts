"""Private JSON-lines subprocess protocol. stdout is protocol-only.

No listening port, text logging, cloud calls, or persistent audio files.
"""
from __future__ import annotations

import contextlib
import json
import sys

from .engine import Engine, VOICES
from .models import ready
from .text import prepare


def dispatch(request, engine):
    op = request.get("op")
    if op == "status":
        return {"ready": ready(), "voices": VOICES, "engine": "Kokoro 82M · INT8 · CPU"}
    if op == "prepare":
        clean = request.get("clean", True)
        if not isinstance(clean, bool):
            raise ValueError("clean must be a boolean")
        return prepare(request.get("text", ""), clean)
    if op == "synthesize":
        return engine.synthesize(request.get("text", ""), request.get("voice", "af_heart"))
    raise ValueError("Unknown worker operation")


def main():
    engine = Engine()
    for line in sys.stdin:
        request_id = None
        try:
            if len(line) > 2_000_000:
                raise ValueError("Request is too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Request must be an object")
            request_id = request.get("id")
            # Third-party library diagnostics must never corrupt the wire protocol.
            with contextlib.redirect_stdout(sys.stderr):
                result = dispatch(request, engine)
            response = {"id": request_id, "ok": True, "result": result}
        except Exception as error:
            # Only controlled errors go back; avoid printing user content in tracebacks.
            message = str(error) if isinstance(error, (ValueError, RuntimeError)) else f"Speech worker failed ({type(error).__name__}). Check local setup."
            response = {"id": request_id, "ok": False, "error": message}
        print(json.dumps(response, ensure_ascii=True), flush=True)


if __name__ == "__main__":
    main()

import json
import os
import subprocess
import sys
import unittest

from hush_tts.engine import Engine


class WorkerProtocolTests(unittest.TestCase):
    def test_invalid_request_does_not_kill_worker(self):
        requests = ["not json", "[]", json.dumps({"id": "bad", "op": "unknown"}),
                    json.dumps({"id": "prepare", "op": "prepare", "text": "A sentence. Another one."})]
        result = subprocess.run([sys.executable, "-m", "hush_tts.worker"],
                                input="\n".join(requests) + "\n", text=True,
                                capture_output=True, timeout=10, env=os.environ)
        self.assertEqual(result.returncode, 0)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r["ok"] for r in replies], [False, False, False, True])
        self.assertEqual(replies[-1]["id"], "prepare")
        self.assertEqual(len(replies[-1]["result"]["segments"]), 2)

    def test_engine_validates_before_loading(self):
        engine = Engine()
        for text, voice in [("", "af_heart"), ("Hello", "unknown"), ("a" * 501, "af_heart")]:
            with self.assertRaises(ValueError):
                engine.synthesize(text, voice)
        self.assertIsNone(engine.model)


if __name__ == "__main__":
    unittest.main()

"""scripts/fetch.agc `model`, against a local server that redirects and serves byte ranges (the way Hugging Face and
its CDN do): the download follows the redirect, takes the file in pieces and checks its sha256.

Run from the repo root: `python3 -m unittest tests.test_fetch`.
"""
import hashlib
import http.server
import os
import re
import subprocess
import tempfile
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTICA = os.environ.get("AGENTICA", "agentica")
SCRIPT = os.path.join(ROOT, "scripts", "fetch.agc")
# More than one piece of the download (32 MiB), and not a whole number of them.
DATA = (bytes(range(256)) * 4096) * 34 + b"tail of the file"
SHA256 = hashlib.sha256(DATA).hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/Org/Repo/resolve/main/m.gguf":
            self.send_response(302)
            self.send_header("Location", "/cdn/m.gguf")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/cdn/m.gguf":
            first, last = 0, len(DATA) - 1
            match = re.match(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
            if match:
                first, last = int(match.group(1)), min(int(match.group(2)), len(DATA) - 1)
            body = DATA[first:last + 1]
            self.send_response(206 if match else 200)
            if match:
                self.send_header("Content-Range", f"bytes {first}-{last}/{len(DATA)}")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass


class FetchModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def fetch(self, cwd, sha256):
        env = {**os.environ, "HF_ENDPOINT": f"http://127.0.0.1:{self.server.server_address[1]}"}
        return subprocess.run([AGENTICA, SCRIPT, "model", "Org/Repo", "m.gguf", sha256], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=120)

    def test_the_model_is_downloaded_through_the_redirect_in_pieces_and_checked(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as cwd:
            result = self.fetch(cwd, SHA256)
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(os.path.join(cwd, "deps", "m.gguf"), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), SHA256)
            self.assertEqual(os.listdir(os.path.join(cwd, "deps")), ["m.gguf"])
            again = self.fetch(cwd, SHA256)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertIn("already fetched", again.stdout)

    def test_a_wrong_sha256_fails_and_leaves_no_file(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as cwd:
            result = self.fetch(cwd, "0" * 64)
            self.assertEqual(result.returncode, 1)
            self.assertIn("sha256 is " + SHA256, result.stderr)
            self.assertEqual(os.listdir(os.path.join(cwd, "deps")), [])


if __name__ == "__main__":
    unittest.main()

"""The command line of server.agc, end to end and without a model: the run ends at the command line or at the load.

Needs scripts/fetch-llama.sh (the manifest names the native files) and the agentica binary in AGENTICA (default:
`agentica` on PATH). Run from the repo root: `python3 -m unittest tests.test_cli`.
"""
import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTICA = os.environ.get("AGENTICA", "agentica")


def server(*args):
    return subprocess.run([AGENTICA, "server.agc", *args], cwd=ROOT, capture_output=True, text=True, timeout=60)


class CliTest(unittest.TestCase):
    def test_help_lists_every_option_and_exits_0(self):
        result = server("--help")
        self.assertEqual(result.returncode, 0)
        for name in ["model", "backends", "host", "port", "threads", "ctx", "parallel", "batch", "stats"]:
            self.assertIn(f"--{name}", result.stdout)
        self.assertIn("(default: 8080)", result.stdout)

    def test_bad_value_names_the_option_and_exits_2(self):
        result = server("--port", "abc")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid value for --port: 'abc' is not an Int", result.stderr)

    def test_unknown_option_exits_2(self):
        result = server("--bogus", "1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown option --bogus", result.stderr)

    def test_valid_flags_reach_the_model_load(self):
        # Every flag in one of its forms; the command line is accepted, so the run fails at the missing model.
        result = server(
            "--model", "/nonexistent.gguf", "--backends", "native/linux", "--host", "127.0.0.1", "--port=0",
            "--threads", "2", "--ctx", "4096", "--parallel", "4", "--batch", "512", "--stats", "on")
        self.assertEqual(result.returncode, 1)
        self.assertIn("error: cannot load the model at /nonexistent.gguf", result.stdout)


if __name__ == "__main__":
    unittest.main()

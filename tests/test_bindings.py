"""scripts/check-bindings.py: it accepts llama.agc, and fails with a diff when a struct or a function is wrong.

Needs scripts/fetch-headers.sh. Run from the repo root: `python3 -m unittest tests.test_bindings`.
"""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "src", "llama_server", "llama.agc")


def check(text, *args):
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        path = os.path.join(tmp, "llama.agc")
        with open(path, "w") as f:
            f.write(text)
        return subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "check-bindings.py"), "--source", path, "--skip-sizes", *args],
            capture_output=True, text=True, timeout=60)


class BindingsTest(unittest.TestCase):
    def setUp(self):
        with open(SOURCE) as f:
            self.text = f.read()

    def mutated(self, old, new):
        self.assertIn(old, self.text)
        return self.text.replace(old, new, 1)

    def test_the_committed_bindings_match_the_headers_with_their_sizes(self):
        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "check-bindings.py")], capture_output=True, text=True,
            timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_removed_field_fails_with_a_diff(self):
        result = check(self.mutated("    n_ubatch: C.UInt32\n", ""))
        self.assertEqual(result.returncode, 1)
        self.assertIn("struct ContextParams (llama_context_params) differs", result.stderr)
        self.assertIn("-n_ubatch: uint32_t", result.stderr)

    def test_reordered_fields_fail(self):
        result = check(self.mutated("    n_batch: C.UInt32\n    n_ubatch: C.UInt32\n",
                                    "    n_ubatch: C.UInt32\n    n_batch: C.UInt32\n"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("struct ContextParams (llama_context_params) differs", result.stderr)

    def test_a_wrong_field_type_fails(self):
        result = check(self.mutated("    n_seq_max: C.UInt32\n", "    n_seq_max: C.Int64\n"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("n_seq_max", result.stderr)

    def test_a_function_with_a_missing_parameter_fails(self):
        result = check(self.mutated("def llama_vocab_is_eog(vocab: C.Pointer, token: C.Int32)", "def llama_vocab_is_eog(vocab: C.Pointer)"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_vocab_is_eog: header takes 2 parameters", result.stderr)

    def test_a_function_with_a_wrong_type_fails(self):
        result = check(self.mutated("def llama_sampler_init_temp(t: C.Float)", "def llama_sampler_init_temp(t: C.Double)"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_sampler_init_temp parameter 1", result.stderr)

    def test_a_function_that_is_not_in_the_headers_fails(self):
        result = check(self.mutated("def llama_backend_init()", "def llama_backend_start()"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_backend_start is not in the headers", result.stderr)


if __name__ == "__main__":
    unittest.main()

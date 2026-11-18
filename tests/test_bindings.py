"""scripts/check-bindings.py: it accepts llama.agc, and fails with a diff when a struct or a function is wrong.

Needs scripts/fetch-headers.sh. Run from the repo root: `python3 -m unittest tests.test_bindings`.
"""
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "src", "llama_server", "llama.agc")


SCRIPT = os.path.join(ROOT, "scripts", "check-bindings.py")


def check(text, *args, skip_sizes=True):
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        path = os.path.join(tmp, "llama.agc")
        with open(path, "w") as f:
            f.write(text)
        flags = ["--skip-sizes"] if skip_sizes else []
        return subprocess.run([sys.executable, SCRIPT, "--source", path, *flags, *args], capture_output=True,
                              text=True, timeout=60)


def script_module():
    spec = importlib.util.spec_from_file_location("check_bindings", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BindingsTest(unittest.TestCase):
    def setUp(self):
        with open(SOURCE) as f:
            self.text = f.read()

    def mutated(self, old, new):
        self.assertIn(old, self.text)
        return self.text.replace(old, new, 1)

    def test_the_committed_bindings_match_the_headers_with_their_sizes(self):
        result = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, timeout=120)
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

    def test_a_resource_freed_by_the_wrong_function_fails(self):
        result = check(self.mutated("resource Model, free: llama_model_free", "resource Model, free: llama_free"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_free parameter 1", result.stderr)

    def test_a_resource_in_the_place_of_another_fails(self):
        result = check(self.mutated("def llama_decode(ctx: Context,", "def llama_decode(ctx: Model,"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_decode parameter 1", result.stderr)

    def test_a_resource_as_the_result_of_another_pointer_fails(self):
        result = check(self.mutated("def llama_model_get_vocab(model: Model) -> C.Pointer",
                                    "def llama_model_get_vocab(model: Model) -> Model"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_model_get_vocab result", result.stderr)

    def test_a_wrong_constant_of_the_helpers_fails(self):
        result = check(self.mutated("CHAT_MESSAGE_BYTES = 16", "CHAT_MESSAGE_BYTES = 24"), skip_sizes=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("chat_message_bytes: C has 16, llama.agc assumes 24", result.stderr)

    def test_a_size_that_differs_from_the_c_one_fails(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
            fake = os.path.join(tmp, "agentica")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\necho 'ModelParams 80'\necho 'ContextParams 176'\necho 'Batch 48'\n"
                        "echo 'SamplerChainParams 1'\n")
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            result = check(self.text, "--agentica", fake, skip_sizes=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("sizeof differs", result.stderr)
        self.assertIn("-Batch 56", result.stderr)
        self.assertIn("+Batch 48", result.stderr)

    def test_a_field_the_check_cannot_read_is_an_error_not_a_crash(self):
        module = script_module()
        for field in ["int (*cb)(int) ", "float v[4] ", "int a : 3 ", "int a, b "]:
            with self.assertRaises(module.Unsupported, msg=field):
                module.Header(f"struct s {{ {field}; }};").struct_fields("s")
        with self.assertRaises(module.Unsupported):
            module.Header("struct s { union { int a; float b; } u; };").struct_fields("s")

    def test_a_call_in_an_inline_body_is_not_the_declaration(self):
        header = script_module().Header("static inline void f(void) { return g(1); }\nint g(int x);\n")
        self.assertEqual(header.function("g"), ("int", ["int"]))

    def test_unsigned_is_read_as_a_32_bit_integer(self):
        module = script_module()
        header = module.Header("")
        self.assertEqual(header.kind("unsigned int"), ("scalar", {"C.UInt32"}))
        self.assertEqual(header.kind("unsigned"), ("scalar", {"C.UInt32"}))
        with self.assertRaises(module.Unsupported):
            header.kind("unsigned long")


if __name__ == "__main__":
    unittest.main()

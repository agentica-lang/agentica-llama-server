"""scripts/check_bindings.agc: it accepts llama.agc, and fails with a message when a struct or a function is wrong.

Needs `agentica scripts/fetch.agc headers` and `llama`. Run from the repo root:
`python3 -m unittest tests.test_bindings`.
"""
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "src", "llama_server", "llama.agc")
HEADERS = os.path.join(ROOT, "deps", "headers")
AGENTICA = os.environ.get("AGENTICA", "agentica")
SCRIPT = os.path.join(ROOT, "scripts", "check_bindings.agc")


def read(path):
    with open(path) as f:
        return f.read()


def tmpdir():
    return tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))


def check(text=None, *args, headers=None, skip_sizes=True, env=None, agentica=AGENTICA):
    with tmpdir() as tmp:
        path = os.path.join(tmp, "llama.agc")
        with open(path, "w") as f:
            f.write(text if text is not None else read(SOURCE))
        flags = ["--skip-sizes"] if skip_sizes else []
        if headers:
            flags += ["--headers", headers]
        return subprocess.run([agentica, SCRIPT, "--source", path, *flags, *args], cwd=ROOT, capture_output=True,
                              text=True, timeout=120, env=env)


def header_dir(tmp, header_text):
    os.makedirs(tmp, exist_ok=True)
    with open(os.path.join(tmp, "llama.h"), "w") as f:
        f.write(header_text)
    return tmp


class BindingsTest(unittest.TestCase):
    def setUp(self):
        self.text = read(SOURCE)

    def mutated(self, old, new):
        self.assertIn(old, self.text)
        return self.text.replace(old, new, 1)

    def test_the_committed_bindings_match_the_headers_with_their_sizes(self):
        result = check(skip_sizes=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bindings ok", result.stdout)

    def test_a_removed_field_fails(self):
        result = check(self.mutated("    n_ubatch: C.UInt32\n", ""))
        self.assertEqual(result.returncode, 1)
        self.assertIn("struct ContextParams (llama_context_params): n_ubatch is missing from llama.agc", result.stderr)

    def test_reordered_fields_fail(self):
        result = check(self.mutated("    n_batch: C.UInt32\n    n_ubatch: C.UInt32\n",
                                    "    n_ubatch: C.UInt32\n    n_batch: C.UInt32\n"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("struct ContextParams (llama_context_params): the order differs at field 2", result.stderr)

    def test_a_wrong_field_type_fails(self):
        result = check(self.mutated("    n_seq_max: C.UInt32\n", "    n_seq_max: C.Int64\n"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("n_seq_max: the header has `uint32_t`, llama.agc `C.Int64`", result.stderr)

    def test_a_function_with_a_missing_parameter_fails(self):
        result = check(self.mutated("def llama_vocab_is_eog(vocab: C.Pointer, token: C.Int32)",
                                    "def llama_vocab_is_eog(vocab: C.Pointer)"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("llama_vocab_is_eog: the header takes 2 parameters", result.stderr)

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
        with tmpdir() as tmp:
            headers = os.path.join(tmp, "headers")
            shutil.copytree(HEADERS, headers)
            path = os.path.join(headers, "llama.h")
            text = read(path)
            old = "bool no_perf; // whether to measure performance timings"
            self.assertIn(old, text)
            with open(path, "w") as f:
                f.write(text.replace(old, "int32_t no_perf; // whether to measure performance timings", 1))
            result = check(headers=headers, skip_sizes=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("sizeof SamplerChainParams: the C compiler says 4, Native.size_of says 1", result.stderr)

    def test_without_a_c_compiler_it_says_so(self):
        agentica = shutil.which(AGENTICA)
        result = check(skip_sizes=False, env={"PATH": "/nonexistent"}, agentica=agentica)
        self.assertEqual(result.returncode, 2)
        self.assertIn("needs a C compiler (cc) to compare the sizes, or use --skip-sizes", result.stderr)

    def test_a_field_the_check_cannot_read_is_an_error_not_a_crash(self):
        fields = ["int (*cb)(int);", "float v[4];", "int a : 3;", "int a, b;", "union { int a; float b; } u;"]
        for field in fields:
            with self.subTest(field=field), tmpdir() as tmp:
                headers = header_dir(tmp, f"struct llama_batch {{ {field} }};\n")
                result = check(headers=headers)
                self.assertEqual(result.returncode, 1)
                self.assertIn("unsupported field", result.stderr)

    def test_a_call_in_an_inline_body_is_not_the_declaration(self):
        source = 'extern "x"\n  def g(x: C.Int32) -> C.Int32\nend\n'
        with tmpdir() as tmp:
            headers = header_dir(tmp, "static inline void f(void) { return g(1); }\nint g(int x);\n")
            result = check(source, headers=headers)
        self.assertNotIn("g parameter", result.stderr)
        self.assertNotIn("g result", result.stderr)
        self.assertNotIn("g is not in the headers", result.stderr)

    def test_unsigned_is_a_32_bit_integer_and_unsigned_long_is_refused(self):
        source = 'extern "x"\n  def h(a: C.UInt32, b: C.UInt32) -> Void\n  def k(a: C.UInt64) -> Void\nend\n'
        with tmpdir() as tmp:
            headers = header_dir(tmp, "void h(unsigned int a, unsigned b);\nvoid k(unsigned long a);\n")
            result = check(source, headers=headers)
        self.assertNotIn("h parameter", result.stderr)
        self.assertIn("k parameter 1: unsupported C type `unsigned long`", result.stderr)


if __name__ == "__main__":
    unittest.main()

## scripts/check_bindings.agc as a program: it accepts llama.agc, and fails naming the struct or the function when
## a copy of llama.agc is wrong. `agentica test` runs it from the repo root; it needs deps/headers (make fetch).

SOURCE = "src/llama_server/llama.agc"
HEADERS = "deps/headers"
SCRIPT = "scripts/check_bindings.agc"
TIMEOUT_MS = 120_000

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def agentica() -> String = System.env("AGENTICA").unwrap_or("agentica")

def run_in(command: String, args: List[String], env: Map[String, String]) -> Result[Ran]
  process = try Process.spawn_captured(command, args, Process.Options(timeout_ms: TIMEOUT_MS, env: env))
  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

## A folder of its own for one test, under TMPDIR.
def scratch(name: String) -> Result[String]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([base, "bindings-test-#{System.pid()}-#{name}"])
  try Path.remove(dir)
  try Dir.mkdir(dir)
  ok(dir)
end

## Runs the check on `text` in the place of llama.agc, with the given headers and flags.
def check(name: String, text: String, headers: String, flags: List[String], env: Map[String, String]) -> Result[Ran]
  dir = try scratch(name + "-source")
  source = try Path.join([dir, "llama.agc"])
  try File.write_text(source, text)
  ran = run_in(agentica(), [SCRIPT, "--source", source, "--headers", headers] + flags, env)
  _ = Path.remove(dir)
  ran
end

def check_text(name: String, text: String) -> Result[Ran] = check(name, text, HEADERS, ["--skip-sizes"], {})

## `text` with the first `old` replaced.
def replace_first(text: String, old: String, new: String) -> Result[String]
  parts = text.split(old)
  return error("no `#{old}` in the text") if parts.size < 2

  ok(parts.first + new + parts.drop(1).join(old))
end

def mutated(old: String, new: String) -> Result[String] = replace_first(try File.read_text(SOURCE), old, new)

def fails_with(name: String, old: String, new: String, message: String) -> Result[Void]
  ran = try check_text(name, try mutated(old, new))
  try Test.eq(ran.code, 1)
  Test.assert(ran.stderr.include?(message), "stderr lacks `#{message}`:\n#{ran.stderr}")
end

def pinned_tag() -> Result[String] = ok((try File.read_text("scripts/llama-release")).split(" ")[0])

## Runs the check on `source` against a lone llama.h with `header_text`.
def check_header(name: String, source: String, header_text: String) -> Result[Ran]
  dir = try scratch(name)
  headers = try Path.join([dir, "headers"])
  try Dir.mkdir(headers)
  try File.write_text(try Path.join([headers, "llama.h"]), header_text)
  try File.write_text(try Path.join([headers, "TAG"]), try pinned_tag())
  ran = check(name, source, headers, ["--skip-sizes"], {})
  _ = Path.remove(dir)
  ran
end

def test_the_committed_bindings_match_the_headers_with_their_sizes() -> Result[Void]
  ran = try run_in(agentica(), [SCRIPT], {})
  try Test.eq(ran.code, 0)
  Test.assert(ran.stdout.include?("bindings ok"), "stdout: #{ran.stdout}\nstderr: #{ran.stderr}")
end

def test_a_removed_field_fails() -> Result[Void]
  fails_with(
    "removed",
    "    n_ubatch: C.UInt32\n",
    "",
    "struct ContextParams (llama_context_params): n_ubatch is missing from llama.agc",
  )
end

def test_swapped_fields_fail() -> Result[Void]
  fails_with(
    "swapped",
    "    n_batch: C.UInt32\n    n_ubatch: C.UInt32\n",
    "    n_ubatch: C.UInt32\n    n_batch: C.UInt32\n",
    "struct ContextParams (llama_context_params): the order differs at field 2",
  )
end

def test_a_wrong_field_type_fails() -> Result[Void]
  fails_with(
    "field-type",
    "    n_seq_max: C.UInt32\n",
    "    n_seq_max: C.Int64\n",
    "struct ContextParams (llama_context_params): n_seq_max: the header has `uint32_t`, llama.agc `C.Int64`",
  )
end

def test_a_missing_parameter_fails() -> Result[Void]
  fails_with(
    "missing-param",
    "def llama_vocab_is_eog(vocab: C.Pointer, token: C.Int32)",
    "def llama_vocab_is_eog(vocab: C.Pointer)",
    "llama_vocab_is_eog: the header takes 2 parameters",
  )
end

def test_a_wrong_parameter_type_fails() -> Result[Void]
  fails_with(
    "param-type",
    "def llama_sampler_init_temp(t: C.Float)",
    "def llama_sampler_init_temp(t: C.Double)",
    "llama_sampler_init_temp parameter 1",
  )
end

def test_an_unknown_function_fails() -> Result[Void]
  fails_with(
    "unknown",
    "def llama_backend_init()",
    "def llama_backend_start()",
    "llama_backend_start is not in the headers",
  )
end

def test_a_resource_freed_by_the_wrong_function_fails() -> Result[Void]
  fails_with(
    "free",
    "resource Model, free: llama_model_free",
    "resource Model, free: llama_free",
    "llama_free parameter 1",
  )
end

def test_a_resource_in_the_place_of_another_fails() -> Result[Void]
  try fails_with(
    "swap-parameter",
    "def llama_decode(ctx: Context,",
    "def llama_decode(ctx: Model,",
    "llama_decode parameter 1",
  )

  fails_with(
    "swap-result",
    "def llama_model_get_vocab(model: Model) -> C.Pointer",
    "def llama_model_get_vocab(model: Model) -> Model",
    "llama_model_get_vocab result",
  )
end

def test_a_wrong_helper_constant_fails() -> Result[Void]
  text = try mutated("CHAT_MESSAGE_BYTES = 16", "CHAT_MESSAGE_BYTES = 24")
  ran = try check("constant", text, HEADERS, [], {})
  try Test.eq(ran.code, 1)
  message = "chat_message_bytes: C has 16, llama.agc assumes 24"
  Test.assert(ran.stderr.include?(message), "stderr lacks `#{message}`:\n#{ran.stderr}")
end

def test_a_size_that_differs_from_the_c_one_fails() -> Result[Void]
  dir = try scratch("size")
  headers = try Path.join([dir, "headers"])
  try Dir.mkdir(headers)
  for name in try Dir.list(HEADERS)
    try File.write_text(try Path.join([headers, name]), try File.read_text(try Path.join([HEADERS, name])))
  end

  path = try Path.join([headers, "llama.h"])
  old = "bool no_perf; // whether to measure performance timings"
  try File.write_text(
    path,
    try replace_first(try File.read_text(path), old, "int32_t no_perf; // whether to measure performance timings"),
  )

  source = try File.read_text(SOURCE)
  ran = try check("size", source, headers, [], {})
  _ = Path.remove(dir)
  try Test.eq(ran.code, 1)
  message = "sizeof SamplerChainParams: the C compiler says 4, Native.size_of says 1"
  Test.assert(ran.stderr.include?(message), "stderr lacks `#{message}`:\n#{ran.stderr}")
end

def test_without_a_c_compiler_it_says_so() -> Result[Void]
  source = try File.read_text(SOURCE)
  ran = try check("no-cc", source, HEADERS, [], {"PATH": "/nonexistent"})
  try Test.eq(ran.code, 2)
  message = "needs a C compiler (cc) to compare the sizes, or use --skip-sizes"
  Test.assert(ran.stderr.include?(message), "stderr lacks `#{message}`:\n#{ran.stderr}")
end

def test_a_field_the_check_cannot_read_is_an_error() -> Result[Void]
  fields = ["int (*cb)(int);", "float v[4];", "int a : 3;", "int a, b;", "union { int a; float b; } u;"]
  source = try File.read_text(SOURCE)
  for field in fields
    ran = try check_header("unsupported", source, "struct llama_batch { #{field} };\n")
    try Test.eq(ran.code, 1)
    try Test.assert(ran.stderr.include?("unsupported field"), "`#{field}`: stderr:\n#{ran.stderr}")
  end

  ok()
end

def test_a_call_in_an_inline_body_is_not_a_declaration() -> Result[Void]
  source = "extern \"x\"\n  def g(x: C.Int32) -> C.Int32\nend\n"
  ran = try check_header("inline", source, "static inline void f(void) { return g(1); }\nint g(int x);\n")
  try Test.assert(!ran.stderr.include?("g parameter"), ran.stderr)
  try Test.assert(!ran.stderr.include?("g result"), ran.stderr)
  Test.assert(!ran.stderr.include?("g is not in the headers"), ran.stderr)
end

def test_unsigned_is_32_bits_and_unsigned_long_is_refused() -> Result[Void]
  source = "extern \"x\"\n  def h(a: C.UInt32, b: C.UInt32) -> Void\n  def k(a: C.UInt64) -> Void\nend\n"
  ran = try check_header("unsigned", source, "void h(unsigned int a, unsigned b);\nvoid k(unsigned long a);\n")
  try Test.assert(!ran.stderr.include?("h parameter"), ran.stderr)
  Test.assert(ran.stderr.include?("k parameter 1: unsupported C type `unsigned long`"), ran.stderr)
end

def test_a_size_t_bound_as_a_32_bit_integer_fails() -> Result[Void]
  fails_with(
    "size-t",
    "    moe_cache_size: C.Int64\n",
    "    moe_cache_size: C.Int32\n",
    "moe_cache_size: the header has `size_t`, llama.agc `C.Int32`",
  )
end

def test_the_first_declaration_of_a_function_wins() -> Result[Void]
  source = "extern \"x\"\n  def g(x: C.Int32) -> C.Int32\nend\n"
  ran = try check_header("duplicate", source, "int g(int x);\nint g(int x, int y);\n")
  Test.assert(!ran.stderr.include?("g: the header takes"), ran.stderr)
end

def test_headers_of_another_release_fail() -> Result[Void]
  dir = try scratch("stale")
  headers = try Path.join([dir, "headers"])
  try Dir.mkdir(headers)
  try File.write_text(try Path.join([headers, "TAG"]), "b0")
  ran = try check("stale", try File.read_text(SOURCE), headers, ["--skip-sizes"], {})
  _ = Path.remove(dir)
  try Test.eq(ran.code, 2)
  Test.assert(ran.stderr.include?("is not from scripts/llama-release"), ran.stderr)
end

def test_a_field_line_without_a_type_is_an_error_not_a_crash() -> Result[Void]
  ran = try check_text("no-type", try mutated("    n_ubatch: C.UInt32\n", "    n_ubatch\n"))
  try Test.eq(ran.code, 2)
  Test.assert(ran.stderr.include?("`n_ubatch` in struct ContextParams is not `name: Type`"), ran.stderr)
end

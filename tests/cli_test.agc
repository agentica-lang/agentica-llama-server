## The command line of server.agc, end to end and without a model: the run ends at the command line or at the load.
## `agentica test` runs it from the repo root; it needs `agentica scripts/fetch.agc llama` (the manifest names the
## native files) and `agentica install`.

TIMEOUT_MS = 60_000

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def server(args: List[String]) -> Result[Ran]
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  process = try Process.spawn_captured(agentica, ["server.agc"] + args, Process.Options(timeout_ms: TIMEOUT_MS))
  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def says(text: String, expected: String) -> Result[Void]
  Test.assert(text.include?(expected), "no `#{expected}` in:\n#{text}")
end

def test_help_lists_every_option_and_exits_0() -> Result[Void]
  ran = try server(["--help"])
  try Test.eq(ran.code, 0)
  for name in ["model", "backends", "host", "port", "threads", "ctx", "parallel", "batch", "stats"]
    try says(ran.stdout, "--#{name}")
  end

  says(ran.stdout, "[default: 8080]")
end

def test_a_bad_value_names_the_option_and_exits_2() -> Result[Void]
  ran = try server(["--port", "abc"])
  try Test.eq(ran.code, 2)
  says(ran.stderr, "invalid value for --port: 'abc' is not an Int")
end

def test_stats_takes_only_on_or_off() -> Result[Void]
  ran = try server(["--stats", "maybe"])
  try Test.eq(ran.code, 2)
  says(ran.stderr, "invalid value for --stats: 'maybe' is not one of on, off")
end

def test_an_unknown_option_exits_2() -> Result[Void]
  ran = try server(["--bogus", "1"])
  try Test.eq(ran.code, 2)
  says(ran.stderr, "unknown option --bogus")
end

## Every flag in one of its forms; the command line is accepted, so the run fails at the missing model.
def test_valid_flags_reach_the_model_load() -> Result[Void]
  flags = [
    "--model", "/nonexistent.gguf", "--backends", "native/linux", "--host", "127.0.0.1", "--port=0", "--threads", "2",
    "--ctx", "4096", "--parallel", "4", "--batch", "512", "--stats", "on",
  ]

  ran = try server(flags)
  try Test.eq(ran.code, 1)
  says(ran.stdout, "error: cannot load the model at /nonexistent.gguf")
end

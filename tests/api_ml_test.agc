## The same end-to-end checks as `api_test.agc`, against `server_ml.agc` on a tiny random Qwen3 (`tiny_qwen3.agc`) on the
## reference backend: it needs no model download, no llama.cpp library and no ggml. `agentica test` runs it from the
## repo root. The server and its log (tests/server_ml.log) are the test's, and so is the folder of the model.

import Cases from "api_cases"
import Tiny from "tiny_qwen3"

LOG = "tests/server_ml.log"

def main() -> Void
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/llama-server-tiny-qwen3-#{Time.now_ms()}"
  started = serve(dir)
  _ = Path.remove(dir)
  if !started.ok?
    IO.warn("api_ml_test: #{started.message}")
    System.exit(1)
  end
end

def serve(dir: String) -> Result[Void]
  try write_model(dir)
  port = try Cases.free_port()
  args = [
    "server_ml.agc",
    "--model",
    dir,
    "--backend",
    "reference",
    "--port",
    port.to_s,
    "--ctx",
    Tiny.MAX_POSITIONS.to_s,
  ]

  options = Process.Options(timeout_ms: Cases.TIMEOUT_MS, out: LOG, err: LOG)
  server = try Process.spawn(System.env("AGENTICA").unwrap_or("agentica"), args, options)
  try Cases.wait_ready(server, port, LOG)
  Test.run(
    Cases.tests(port) +
    [
      Test.test("a role the template does not know is 400") do Test.eq(try Cases.role_status(port, "tool"), 400) end,
      Test.test("the process loads no llama.cpp library") do loads_no_llama(server) end,
    ],
  )

  ok()
end

def write_model(dir: String) -> Result[Void]
  program = System.env("AGENTICA").unwrap_or("agentica")
  writer = try Process.spawn(program, ["tests/tiny_qwen3.agc", dir], Process.Options(timeout_ms: Cases.TIMEOUT_MS))
  code = try Process.wait(writer, Cases.TIMEOUT_MS)
  return error("tests/tiny_qwen3.agc exited with #{code}") if code != 0

  ok()
end

## The ml engine must not share a process with llama.cpp's libggml: ml's ggml module links its own.
def loads_no_llama(server: Process) -> Result[Void]
  maps = try File.read_text("/proc/#{try Process.pid(server)}/maps")
  Test.assert(not maps.include?("libllama") and not maps.include?("libggml"), "a llama.cpp library is mapped")
end

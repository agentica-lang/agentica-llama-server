## End-to-end check of the server: starts `server.agc` on a free port with the small model and talks HTTP to it.
## `agentica test` runs it from the repo root; it needs `agentica scripts/fetch.agc all` and `agentica install`. The
## server and its log (tests/server.log) are the test's: the process is closed when the run ends, failed or not.

import Cases from "api_cases"

LOG = "tests/server.log"

def main() -> Void
  started = serve()
  if !started.ok?
    IO.warn("api_test: #{started.message}")
    System.exit(1)
  end
end

def serve() -> Result[Void]
  port = try Cases.free_port()
  args = ["server.agc", "--port", port.to_s, "--threads", "2", "--parallel", "4", "--ctx", "4096", "--gpu-layers", "0"]
  options = Process.Options(timeout_ms: Cases.TIMEOUT_MS, out: LOG, err: LOG)
  server = try Process.spawn(System.env("AGENTICA").unwrap_or("agentica"), args, options)
  try Cases.wait_ready(server, port, LOG)
  Test.run(Cases.tests(port))
  ok()
end

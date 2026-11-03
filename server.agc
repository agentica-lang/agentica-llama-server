## The inference server: Bond routes in front of an engine task that batches requests on llama.cpp.
##
## agentica server.agc [--model PATH] [--host H] [--port N] [--threads N] [--ctx N] [--parallel N] [--batch N]
##                     [--backends DIR] [--stats on|off] [--help]

import Api from "src/api"
import Bond from "pkg/bond/bond"
import Cli from "src/cli"
import Engines from "src/engine"
import Llama from "src/llama"
import HTTP from "std/http"
import OP from "std/option_parser"

REQUEST_QUEUE = 4096

struct EngineJob
  model: Llama.Model
  config: Engines.EngineConfig
  requests: Channel[Engines.GenRequest]
end

def main() -> Void
  case Cli.parse(System.args())
    ok(options) -> run(options)
    error(text) -> exit_for(text)
  end
end

# The help goes to stdout and ends the run normally; a mistake of the command line goes to stderr and exits 1.
def exit_for(text: String) -> Void
  if OP.help?(text)
    puts(OP.message(text))
    return
  end

  IO.warn(OP.message(text))
  System.exit(1)
end

def run(options: Cli.Options) -> Void
  case serve(options)
    ok(_) -> puts("stopped")
    error(message) ->
      puts("error: #{message}")
      System.exit(1)
  end
end

def serve(options: Cli.Options) -> Result[Void]
  Llama.init(options.backends)
  model = try Llama.load_model(options.model)
  requests: Channel[Engines.GenRequest] = Channel.new(REQUEST_QUEUE)
  config = Engines.EngineConfig(
    n_ctx: options.n_ctx,
    n_batch: options.n_batch,
    n_parallel: options.parallel,
    threads: options.threads,
    stats: options.stats,
  )
  engine = Task.spawn(&run_engine, EngineJob(model: model, config: config, requests: requests))
  api = Api.new_api(model, requests, "qwen2.5-0.5b-instruct", options.n_ctx)
  server = try Bond.start_with(
    Api.app(api),
    options.host,
    options.port,
    HttpServerOptions(max_connections: 1024, max_body_bytes: 4_194_304),
  )
  puts("listening on #{options.host}:#{Bond.local_port(server)}")
  IO.flush()
  try Bond.wait(server)
  return Task.await(engine)
end

def run_engine(job: EngineJob) -> Result[Void]
  return Engines.run(job.model, job.config, job.requests)
end

## The inference server on the transformers of ml: the same routes as `server.agc`, with an engine that decodes one
## request at a time. It loads no llama.cpp library.
##
## agentica server_ml.agc --model PATH [--name NAME] [--backend ggml|vulkan|reference] [--weights f32|f16]
##                        [--host H] [--port N] [--ctx N] [--help]

import Api from "src/llama_server_web/api"
import Bond from "pkg/bond/bond"
import Contract from "src/llama_server/contract"
import HTTP from "std/http"
import MlCli from "src/llama_server/ml_cli"
import MlEngine from "src/llama_server/ml_engine"
import OP from "std/option_parser"
import Tensor from "pkg/tensor/tensor"

REQUEST_QUEUE = 4096

struct EngineJob
  loaded: MlEngine.Loaded
  requests: Channel[Contract.GenRequest]
end

# `OP.run!` prints the help and exits 0, or prints a mistake of the command line to stderr and exits 2.
def main() -> Void
  (
    System.args()
    |> MlCli.parse()
    |> OP.run!()
    |> run()
  )
end

def run(options: MlCli.Options) -> Void
  case serve(options)
    ok(_) -> puts("stopped")
    error(e) ->
      puts("error: #{e.message}")
      System.exit(1)
  end
end

def serve(options: MlCli.Options) -> Result[Void]
  loaded = try MlEngine.load(options.model, backend_of(options.backend), weights_of(options.weights), options.n_ctx)
  requests: Channel[Contract.GenRequest] = Channel.new(REQUEST_QUEUE)
  engine = Task.spawn_link(&run_engine, EngineJob(loaded: loaded, requests: requests))
  api = Api.new_api(MlEngine.handle(loaded, requests, options.name))
  server = try Bond.start_with(
    Api.app(api),
    options.host,
    options.port,
    HTTP.ServerOptions(max_connections: 1024, max_body_bytes: 4_194_304),
  )

  puts("listening on #{options.host}:#{Bond.local_port(server)}")
  IO.flush()
  try Bond.wait(server)
  Task.await(engine)
  ok()
end

# The engine ends only with an error (it returns when it cannot start): the process ends with it, not hangs.
def run_engine(job: EngineJob) -> Void
  case MlEngine.run(job.loaded, job.requests)
    ok(_) -> nil
    error(e) ->
      IO.warn("engine: #{e.message}")
      System.exit(1)
  end
end

def backend_of(name: String) -> Tensor.Backend
  case name
    "reference" -> Tensor.Backend.Reference
    "vulkan" -> Tensor.Backend.Ggml(Tensor.Device.Vulkan(0))
    _ -> Tensor.Backend.Ggml(Tensor.Device.Cpu)
  end
end

def weights_of(name: String) -> Tensor.Dtype
  return Tensor.Dtype.F16 if name == "f16"

  Tensor.Dtype.F32
end

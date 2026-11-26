## The command line of `server_ml.agc`.

import OP from "std/option_parser"
import {Opt, Kind} from "std/option_parser"

struct Options
  model: String
  name: String
  backend: String
  weights: String
  host: String
  port: Int
  n_ctx: Int
end

## Reads the words of `System.args()`, as `Cli.parse` does for `server.agc`.
def parse(args: List[String]) -> Result[Options]
  parsed = try OP.parse(parser(), args)
  model = try OP.optional_string(parsed, "model").to_result(
    "--model is required: a Hugging Face folder or a .gguf file of a Qwen model",
  )

  name = OP.optional_string(parsed, "name").unwrap_or(last_part(model))

  ok(
    Options(
      model: model,
      name: name,
      backend: OP.string(parsed, "backend"),
      weights: OP.string(parsed, "weights"),
      host: OP.string(parsed, "host"),
      port: OP.int(parsed, "port"),
      n_ctx: OP.int(parsed, "ctx"),
    ),
  )
end

private

def last_part(path: String) -> String
  parts = path.split("/").select { |part| not part.empty? }
  parts.last
end

def parser() -> OP.Parser
  OP.new(
    "agentica server_ml.agc",
    "An OpenAI-shaped chat server on the transformers of ml, one request at a time",
    [],
    [
      Opt(
        name: "model",
        metavar: "PATH",
        help: "folder of the model (config.json, safetensors, tokenizer.json) or a GGUF file",
      ),
      Opt(name: "name", metavar: "NAME", help: "the model name in the answers, the last part of --model by default"),
      Opt(
        name: "backend",
        choices: ["ggml", "vulkan", "reference"],
        default: "ggml",
        help: "ggml on the CPU, ggml on Vulkan device 0, or the slow reference backend",
      ),
      Opt(
        name: "weights",
        choices: ["f32", "f16"],
        default: "f32",
        help: "dtype of the weights in memory (f16 needs ggml or vulkan)",
      ),
      Opt(name: "host", default: "127.0.0.1", help: "address to listen on"),
      Opt(name: "port", kind: Kind.Int, default: "8080", help: "port to listen on, 0 for a free one"),
      Opt(
        name: "ctx",
        kind: Kind.Int,
        default: "4096",
        help: "positions of a prompt and its answer together, at most the model's",
      ),
    ],
  )
end

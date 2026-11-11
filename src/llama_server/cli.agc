## The command line of the server.

import OP from "std/option_parser"
import {Opt, Kind} from "std/option_parser"

export struct Options
  model: String
  backends: String
  host: String
  port: Int
  threads: Int
  n_ctx: Int
  parallel: Int
  n_batch: Int
  stats: Bool
end

## Reads the words of `System.args()`. `--help` and a bad command line are errors: the caller passes the result to
## `OP.run!`, which prints the help or the message and exits.
export def parse(args: List[String]) -> Result[Options]
  parsed = try OP.parse(parser(), args)
  ok(
    Options(
      model: OP.string(parsed, "model"),
      backends: OP.string(parsed, "backends"),
      host: OP.string(parsed, "host"),
      port: OP.int(parsed, "port"),
      threads: OP.int(parsed, "threads"),
      n_ctx: OP.int(parsed, "ctx"),
      parallel: OP.int(parsed, "parallel"),
      n_batch: OP.int(parsed, "batch"),
      stats: OP.string(parsed, "stats") == "on",
    ),
  )
end

def parser() -> OP.Parser
  OP.new(
    "agentica server.agc",
    "An OpenAI-shaped chat server on llama.cpp",
    [],
    [
      Opt(name: "model", metavar: "PATH", default: "deps/qwen2.5-0.5b-instruct-q4_k_m.gguf", help: "GGUF model file"),
      Opt(name: "backends", metavar: "DIR", default: "native/linux", help: "folder of the ggml backend libraries"),
      Opt(name: "host", default: "127.0.0.1", help: "address to listen on"),
      Opt(name: "port", kind: Kind.Int, default: "8080", help: "port to listen on, 0 for a free one"),
      Opt(name: "threads", kind: Kind.Int, default: "8", help: "threads of the engine"),
      Opt(name: "ctx", kind: Kind.Int, default: "8192", help: "tokens of KV cache, shared by the slots"),
      Opt(name: "parallel", kind: Kind.Int, default: "8", help: "slots, the requests decoded together"),
      Opt(name: "batch", kind: Kind.Int, default: "2048", help: "tokens per decode call"),
      Opt(name: "stats", choices: ["on", "off"], default: "off", help: "print engine timings every 5 s of work"),
    ],
  )
end

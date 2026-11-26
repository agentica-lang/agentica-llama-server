## The same end-to-end checks as `api_test.agc`, against `server_ml.agc` on a tiny random Qwen3 (`tiny_qwen3.agc`) on the
## reference backend: it needs no model download, no llama.cpp library and no ggml. `agentica test` runs it from the
## repo root. The servers and their logs (tests/server_ml.log, tests/server_ml_stop.log) are the test's, and so are the
## folders of the models.
##
## Not covered here: the ggml backends (ml's ggml module is not built in CI), so `--backend ggml` is unverified in CI.

import Bpe from "pkg/transformers/tokenizer/bpe"
import Cases from "api_cases"
import MlEngine from "../src/llama_server/ml_engine"
import Tiny from "tiny_qwen3"

LOG = "tests/server_ml.log"
STOP_LOG = "tests/server_ml_stop.log"
SERVER_MS = 300_000
## The tokens of the tests are ASCII bytes, `<|im_end|>` is the id 258 of the model and 0 of the one that stops at once.
BYTE_80 = 128

def main() -> Void
  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/llama-server-tiny-qwen3-#{Time.now_ms()}"
  started = serve(base)
  _ = Path.remove(base)
  if !started.ok?
    IO.warn("api_ml_test: #{started.message}")
    System.exit(1)
  end
end

def serve(base: String) -> Result[Void]
  try Dir.mkdir(base)
  try write_model("#{base}/main", false)
  try write_model("#{base}/stop", true)
  main_port = try Cases.free_port()
  stop_port = try Cases.free_port()
  server = try start("#{base}/main", main_port, LOG)
  stopper = try start("#{base}/stop", stop_port, STOP_LOG)
  try Cases.wait_ready(server, main_port, LOG)
  try Cases.wait_ready(stopper, stop_port, STOP_LOG)
  Test.run(Cases.tests(main_port) + own_tests(main_port, stop_port, "#{base}/main", server))
  ok()
end

def own_tests(port: Int, stop_port: Int, dir: String, server: Process) -> List[Test.Case]
  [
    Test.test("a role the template does not know is 400") do Test.eq(try Cases.role_status(port, "tool"), 400) end,
    Test.test("seeds and temperature change the sampled text") do check_sampling(port) end,
    Test.test("a prompt that leaves two positions gives at most two tokens") do check_context_edge(port) end,
    Test.test("a model that ends the answer at once says stop with no text") do check_stop(stop_port) end,
    Test.test("a character split between tokens waits for its last byte") do check_split_character(dir) end,
    Test.test("broken bytes are released after four tokens") do check_broken_bytes(dir) end,
    Test.test("the process loads no llama.cpp library") do loads_no_llama(server) end,
    Test.test("server_ml.agc imports nothing of llama.cpp") do imports_no_llama() end,
  ]
end

def start(dir: String, port: Int, log: String) -> Result[Process]
  args = [
    "server_ml.agc", "--model", dir, "--backend", "reference", "--port", port.to_s, "--ctx", Tiny.MAX_POSITIONS.to_s,
  ]

  options = Process.Options(timeout_ms: SERVER_MS, out: log, err: log)
  Process.spawn(System.env("AGENTICA").unwrap_or("agentica"), args, options)
end

def write_model(dir: String, stops_at_once: Bool) -> Result[Void]
  args = ["tests/tiny_qwen3.agc", dir]
  if stops_at_once
    args = args.push("stop")
  end

  writer = try Process.spawn(
    System.env("AGENTICA").unwrap_or("agentica"),
    args,
    Process.Options(timeout_ms: SERVER_MS),
  )

  code = try Process.wait(writer, SERVER_MS)
  return error("tests/tiny_qwen3.agc exited with #{code}") if code != 0

  ok()
end

# --- the checks

## The head gives ASCII logits far apart, so the temperature must be high for the draws to differ.
def check_sampling(port: Int) -> Result[Void]
  hot = {"max_tokens": JSON.from(24), "temperature": JSON.from(5.0)}
  seven = Cases.answer(try Cases.chat(port, hot.put("seed", JSON.from(7))))
  eight = Cases.answer(try Cases.chat(port, hot.put("seed", JSON.from(8))))
  greedy = Cases.answer(try Cases.chat(port, Cases.greedy(24)))
  try Test.assert(seven != eight, "seeds 7 and 8 gave #{seven}")
  Test.assert(seven != greedy, "temperature 5 gave the greedy text #{greedy}")
end

## The prompt takes all the context but two positions: the answer cannot pass two tokens.
def check_context_edge(port: Int) -> Result[Void]
  probe = try post_user(port, "a" * 10)
  overhead = probe.usage.prompt_tokens - 10
  edge = try post_user(port, "a" * (Tiny.MAX_POSITIONS - 2 - overhead))
  try Test.eq(edge.usage.prompt_tokens, Tiny.MAX_POSITIONS - 2)
  try Test.assert(edge.usage.completion_tokens <= 2, "#{edge.usage.completion_tokens} tokens")
  Test.eq(edge.choices[0].finish_reason, "length")
end

def post_user(port: Int, text: String) -> Result[Cases.Completion]
  reply = try Cases.post(port, [Cases.Message(role: "user", content: text)], {"max_tokens": JSON.from(50)})
  try Test.eq(reply.status, 200)
  JSON.decode(reply.body, Cases.Completion)
end

def check_stop(port: Int) -> Result[Void]
  done = try Cases.chat(port, Cases.greedy(8))
  try Test.eq(done.choices[0].finish_reason, "stop")
  try Test.eq(Cases.answer(done), "")
  Test.eq(done.usage.completion_tokens, 0)
end

## An emoji is four byte tokens: the first three give no text and the fourth the emoji.
def check_split_character(dir: String) -> Result[Void]
  tokenizer = try Bpe.open("#{dir}/tokenizer.json")
  ids = try Bpe.encode(tokenizer, "🫠")
  try Test.eq(ids.size, 4)
  held: List[Int] = []
  for i in 0...3
    piece = try MlEngine.whole_text(tokenizer, held.push(ids[i]))
    try Test.eq(piece.text, "")
    held = piece.held
  end

  last = try MlEngine.whole_text(tokenizer, held.push(ids[3]))
  try Test.eq(last.text, "🫠")
  Test.eq(last.held.size, 0)
end

## Four continuation bytes are no character: the fourth token releases them as replacement characters, so a stream of
## broken bytes does not wait for ever.
def check_broken_bytes(dir: String) -> Result[Void]
  tokenizer = try Bpe.open("#{dir}/tokenizer.json")
  held: List[Int] = []
  for _ in 0...3
    piece = try MlEngine.whole_text(tokenizer, held.push(BYTE_80))
    try Test.eq(piece.text, "")
    held = piece.held
  end

  released = try MlEngine.whole_text(tokenizer, held.push(BYTE_80))
  try Test.eq(released.text, String.from_code(65533) * 4)
  Test.eq(released.held.size, 0)
end

## The ml engine must not share a process with llama.cpp's libggml: ml's ggml module links its own. The maps of any
## process hold libc, so an empty answer would not pass.
def loads_no_llama(server: Process) -> Result[Void]
  maps = try File.read_text("/proc/#{try Process.pid(server)}/maps")
  try Test.assert(maps.include?("libc"), "the maps of the server are empty")
  Test.assert(not maps.include?("libllama") and not maps.include?("libggml"), "a llama.cpp library is mapped")
end

## The files that `server_ml.agc` imports, from the folder of each importer, never include the llama.cpp bindings or
## their engine.
def imports_no_llama() -> Result[Void]
  seen: List[String] = []
  queue = [try Path.resolve("server_ml.agc")]
  while not queue.empty?
    file = queue[0]
    queue = queue.drop(1)
    next if seen.include?(file)

    seen = seen.push(file)
    for target in try local_imports(file)
      queue = queue.push(target)
    end
  end

  try Test.assert(seen.size >= 5, "only #{seen.size} files were followed")
  for file in seen
    name = file.split("/").last
    try Test.assert(name != "llama.agc" and name != "engine.agc", "#{file} is imported")
  end

  ok()
end

## The files of the imports of `file` that are in this repository (not `std/` or `pkg/`).
def local_imports(file: String) -> Result[List[String]]
  folder = file.split("/").take(file.split("/").size - 1).join("/")
  found: List[String] = []
  for line in (try File.read_text(file)).split("\n")
    if line.start_with?("import ") and line.include?(" from \"")
      path = line.split("\"")[1]
      if not path.start_with?("std/") and not path.start_with?("pkg/")
        found = found.push(try Path.resolve("#{folder}/#{path}.agc"))
      end
    end
  end

  ok(found)
end

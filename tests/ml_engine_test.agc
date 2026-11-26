## The engine of `ml_engine.agc` on its own, on the tiny random Qwen3 of `tiny_qwen3.agc` (reference backend): a long
## request holds the engine while queued requests give up (their replies are closed, as when a handler times out), and
## the next request is answered when the long one ends, not after the ones that left. It decodes in this process, so
## `make test-ml-engine` runs it with `--max-steps unlimited`.

import Contract from "../src/llama_server/contract"
import MlEngine from "../src/llama_server/ml_engine"
import Tensor from "pkg/tensor/tensor"
import Tiny from "tiny_qwen3"

LEAVERS = 6
TIMEOUT_MS = 120_000
## What a request may take after the long one ended: without the skip, six requests of 300 tokens come first.
AFTER_MS = 8000

struct Job
  loaded: MlEngine.Loaded
  requests: Channel[Contract.GenRequest]
end

def test_requests_that_left_do_not_hold_the_engine() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/llama-server-ml-engine-#{Time.now_ms()}"
  result = departed(dir)
  _ = Path.remove(dir)
  result
end

def departed(dir: String) -> Result[Void]
  writer = try Process.spawn(
    System.env("AGENTICA").unwrap_or("agentica"),
    ["tests/tiny_qwen3.agc", dir],
    Process.Options(timeout_ms: TIMEOUT_MS),
  )

  try Test.eq(try Process.wait(writer, TIMEOUT_MS), 0)
  loaded = try MlEngine.load(dir, Tensor.Backend.Reference, Tensor.Dtype.F32, Tiny.MAX_POSITIONS)
  requests: Channel[Contract.GenRequest] = Channel.new(64)
  engine = Task.spawn(&run, Job(loaded: loaded, requests: requests))
  handle = MlEngine.handle(loaded, requests, "tiny")
  prompt = try handle.prompt.call([Contract.Message(role: "user", content: "Name three colors.")])

  holder = try submit(requests, prompt, 200)
  for _ in 0...LEAVERS
    gone = try submit(requests, prompt, 300)
    gone.close
  end

  next_one = try submit(requests, prompt, 4)
  try Test.eq((try holder.recv(TIMEOUT_MS)).completion_tokens, 200)
  ended = Time.monotonic_ms()
  answer = try next_one.recv(TIMEOUT_MS)
  waited = Time.monotonic_ms() - ended
  Task.cancel(engine)
  try Test.eq(answer.completion_tokens, 4)
  Test.assert(waited < AFTER_MS, "the request waited #{waited} ms after the long one")
end

def run(job: Job) -> Result[Void] = MlEngine.run(job.loaded, job.requests)

def submit(
  requests: Channel[Contract.GenRequest],
  prompt: List[Int],
  max_tokens: Int,
) -> Result[Channel[Contract.GenResult]]
  reply: Channel[Contract.GenResult] = Channel.new(1)
  try requests.send(
    Contract.GenRequest(
      prompt: prompt,
      max_tokens: max_tokens,
      temperature: 0.0,
      seed: 0,
      stream: false,
      reply: reply,
    ),
    1000,
  )

  ok(reply)
end

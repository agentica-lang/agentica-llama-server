## Closed-loop load client for an OpenAI-style /v1/chat/completions server.
##
## One task per concurrent client, each with its own keep-alive connection, sending requests back to back until
## `--requests` are done. Prints one JSON object with requests/s, generated tokens/s and latency percentiles. With
## `--stream` every request says `"stream": true` (and asks for the usage chunk) and the client also records the time
## to first token: the time until the first event whose `delta.content` is not empty.
##
## agentica bench/client.agc [--url URL] [--concurrency N] [--requests N] [--max-tokens N] [--extra JSON] [--health]
##                           [--stream] [--texts]

import HTTP from "std/http"
import OP from "std/option_parser"
import {Kind, Opt} from "std/option_parser"

## What one run does.
struct Settings
  url: String
  concurrency: Int
  total: Int
  max_tokens: Int
  extra: Map[String, JSON.Value] = {}
  keep_texts: Bool = false
  health: Bool = false
  stream: Bool = false
end

## The numbers of a run, as the JSON line that the client prints; a field that does not apply stays out of it.
struct RunResult
  concurrency: Int
  requests: Int
  failures: Int
  wall_s: Float
  req_per_s: Float
  gen_tok_per_s: Float
  completion_tokens: Int
  prompt_tokens: Int
  p50_s: Float
  p95_s: Float
  ttft_p50_s: JSON.Field[Float] = JSON.Field.Absent
  ttft_p95_s: JSON.Field[Float] = JSON.Field.Absent
  first_failure: JSON.Field[String] = JSON.Field.Absent
  texts: JSON.Field[Map[String, String]] = JSON.Field.Absent
  neighbour_cores_during: JSON.Field[Float] = JSON.Field.Absent
  busy_cores_before: JSON.Field[Float] = JSON.Field.Absent
  attempts: JSON.Field[Int] = JSON.Field.Absent
  discarded: JSON.Field[List[Discarded]] = JSON.Field.Absent
end

## A run that bench/run_all.agc threw away.
struct Discarded
  gen_tok_per_s: Float
  neighbour_cores_during: Float
end

def main() -> Void
  done = cli(System.args())
  if !done.ok?
    IO.warn("client: #{done.message}")
    System.exit(1)
  end
end

private

SYSTEM = "You are a helpful assistant."
QUESTIONS = [
  "Explain how a hash table works.",
  "Write a short story about a lighthouse keeper.",
  "What are the main causes of the French Revolution?",
  "Describe the water cycle step by step.",
  "Give me a recipe for vegetable soup.",
  "How does a binary search work? Show an example.",
  "Why is the sky blue?",
  "List some tips for learning a new language.",
]
REQUEST_TIMEOUT_MS = 600_000
NANOSECONDS = 1_000_000_000.0

struct Message
  role: String
  content: String
end

struct Piece
  content: Optional[String]
end

struct EventChoice
  delta: Optional[Piece]
end

struct EventUsage
  completion_tokens: Optional[Int]
  prompt_tokens: Optional[Int]
end

struct Event
  choices: Optional[List[EventChoice]]
  usage: Optional[EventUsage]
end

struct Answer
  content: String
end

struct AnswerChoice
  message: Answer
end

struct AnswerUsage
  completion_tokens: Int
  prompt_tokens: Int
end

struct Completion
  choices: List[AnswerChoice]
  usage: AnswerUsage
end

## One finished request.
struct Sample
  index: Int
  seconds: Float
  first_seconds: Float
  completion_tokens: Int
  prompt_tokens: Int
  text: String
end

struct Outcome
  samples: List[Sample]
  failures: List[String]
end

struct Job
  settings: Settings
  indexes: Channel[Int]
end

struct StreamRead
  first_ns: Int
  done_ns: Int
  completion_tokens: Int
  prompt_tokens: Int
  text: String
end

def cli(args: List[String]) -> Result[Void]
  parser = OP.new(
    "agentica bench/client.agc",
    "Closed-loop load client for an OpenAI-style chat server",
    [],
    [
      Opt(name: "url", metavar: "URL", default: "http://127.0.0.1:8080"),
      Opt(name: "concurrency", kind: Kind.Int, default: "1"),
      Opt(name: "requests", kind: Kind.Int, default: "16"),
      Opt(name: "max-tokens", kind: Kind.Int, default: "64"),
      Opt(name: "extra", metavar: "JSON", default: "{}", help: "JSON merged into every request body"),
      Opt(name: "health", kind: Kind.Flag, help: "GET /health instead: the serving layer alone"),
      Opt(name: "stream", kind: Kind.Flag, help: "send \"stream\": true and measure time to first token"),
      Opt(name: "texts", kind: Kind.Flag, help: "include the answers in the output"),
    ],
  )

  parsed = OP.run!(OP.parse(parser, args))
  extra = try extra_fields(OP.string(parsed, "extra"))
  settings = Settings(
    url: OP.string(parsed, "url"),
    concurrency: OP.int(parsed, "concurrency"),
    total: OP.int(parsed, "requests"),
    max_tokens: OP.int(parsed, "max-tokens"),
    extra: extra,
    keep_texts: OP.flag(parsed, "texts"),
    health: OP.flag(parsed, "health"),
    stream: OP.flag(parsed, "stream"),
  )

  puts(JSON.encode(try run(settings)))
  ok()
end

def extra_fields(text: String) -> Result[Map[String, JSON.Value]]
  case JSON.node(try JSON.parse(text))
    JSON.Node.Object(fields) -> ok(fields)
    _ -> error("--extra is not a JSON object")
  end
end

## Runs the clients to the end of the requests; a failed request is counted, the run goes on.
def run(settings: Settings) -> Result[RunResult]
  indexes: Channel[Int] = Channel.new(settings.total + 1)
  for i in 0...settings.total
    try indexes.send(i, 1000)
  end

  indexes.close()
  job = Job(settings: settings, indexes: indexes)
  begin = Time.monotonic_ns()
  tasks = (0...settings.concurrency).map do |_| Task.spawn(&client, job) end
  outcomes = tasks.map do |t| Task.await(t) end
  wall = (Time.monotonic_ns() - begin).to_f() / NANOSECONDS
  ok(summary(settings, outcomes, wall))
end

def client(job: Job) -> Outcome
  conn = HTTP.start(job.settings.url, options())
  samples: List[Sample] = []
  failures: List[String] = []
  while true
    next_index = job.indexes.recv(1000)
    break if !next_index.ok?

    if !conn.ok?
      failures = failures.push(conn.message)
      conn = HTTP.start(job.settings.url, options())
      next
    end

    done = one(job.settings, conn.unwrap!, next_index.unwrap!)
    if done.ok?
      samples = samples.push(done.unwrap!)
    else
      failures = failures.push(done.message)
      HTTP.finish(conn.unwrap!)
      conn = HTTP.start(job.settings.url, options())
    end
  end

  if conn.ok?
    HTTP.finish(conn.unwrap!)
  end

  Outcome(samples: samples, failures: failures)
end

def options() -> HTTP.ClientOptions
  HTTP.ClientOptions(timeout_ms: REQUEST_TIMEOUT_MS, read_timeout_ms: REQUEST_TIMEOUT_MS)
end

## One request on the connection of the client. A stream gets a new connection (llama-server closes the connection
## after a stream although it says keep-alive, so a stream gets one on both servers).
def one(settings: Settings, conn: HTTP.Connection, index: Int) -> Result[Sample]
  started = Time.monotonic_ns()
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  head = try send(settings, conn, index, headers)
  return stream_sample(conn, index, started) if settings.stream and head.status == 200

  raw = try read_all(conn)
  elapsed = seconds(started, Time.monotonic_ns())
  return error("status #{head.status}: #{raw.scrub().slice(0, 200)}") if head.status != 200
  if settings.health
    return ok(
      Sample(index: index, seconds: elapsed, first_seconds: 0.0, completion_tokens: 0, prompt_tokens: 0, text: ""),
    )
  end

  completion = try JSON.decode(try String.from_bytes(raw), Completion)
  ok(
    Sample(
      index: index,
      seconds: elapsed,
      first_seconds: 0.0,
      completion_tokens: completion.usage.completion_tokens,
      prompt_tokens: completion.usage.prompt_tokens,
      text: completion.choices[0].message.content,
    ),
  )
end

def send(
  settings: Settings,
  conn: HTTP.Connection,
  index: Int,
  headers: List[HTTP.Header],
) -> Result[HTTP.ResponseHead]
  return HTTP.send_request(conn, "GET", "/health", "".bytes) if settings.health

  HTTP.send_request(conn, "POST", "/v1/chat/completions", body_for(settings, index), headers)
end

def body_for(settings: Settings, index: Int) -> Bytes
  messages = [
    Message(role: "system", content: SYSTEM),
    Message(role: "user", content: QUESTIONS[index % QUESTIONS.size]),
  ]

  fields = {
    "messages": JSON.from(messages),
    "max_tokens": JSON.from(settings.max_tokens),
    "temperature": JSON.from(0),
    "seed": JSON.from(1),
  }

  if settings.stream
    fields = fields.put("stream", JSON.from(true)).put("stream_options", JSON.from({"include_usage": true}))
  end

  for key in settings.extra.keys
    fields = fields.put(key, settings.extra[key])
  end

  JSON.encode(JSON.object(fields)).bytes
end

def seconds(from: Int, to: Int) -> Float = (to - from).to_f() / NANOSECONDS

def read_all(conn: HTTP.Connection) -> Result[Bytes]
  pieces: List[Bytes] = []
  while true
    piece = try HTTP.read_body(conn, 65_536)
    break if piece.empty?

    pieces = pieces.push(piece)
  end

  ok(Bytes.concat(pieces))
end

# --- streams

## The sample of an SSE chat stream read to `[DONE]`. The connection is drained, so it is ready for the next request.
def stream_sample(conn: HTTP.Connection, index: Int, started: Int) -> Result[Sample]
  read = try read_stream(conn, started)
  _ = read_all(conn)
  ok(
    Sample(
      index: index,
      seconds: seconds(started, read.done_ns),
      first_seconds: seconds(started, read.first_ns),
      completion_tokens: read.completion_tokens,
      prompt_tokens: read.prompt_tokens,
      text: read.text,
    ),
  )
end

def read_stream(conn: HTTP.Connection, started: Int) -> Result[StreamRead]
  pending = "".bytes
  first_ns = -1
  parts: List[String] = []
  completion = 0
  prompt = 0
  while true
    piece = try HTTP.read_body(conn, 65_536)
    return error("stream ended without [DONE]") if piece.empty?

    pending = pending + piece
    cut = last_newline(pending)
    next if cut < 0

    lines = pending.take(cut + 1).scrub().split("\n")
    pending = pending.drop(cut + 1)
    for raw in lines
      line = raw.strip()
      next if !line.start_with?("data:")

      data = line.slice(5, line.length - 5).strip()
      if data == "[DONE]"
        return error("stream without content") if first_ns < 0

        pieces = parts.size
        done = Time.monotonic_ns()
        count = completion
        if count == 0
          count = pieces
        end

        return ok(
          StreamRead(
            first_ns: first_ns,
            done_ns: done,
            completion_tokens: count,
            prompt_tokens: prompt,
            text: parts.join(""),
          ),
        )
      end

      event = try JSON.decode(data, Event)
      if event.usage.some?
        completion = event.usage.unwrap!.completion_tokens.unwrap_or(0)
        prompt = event.usage.unwrap!.prompt_tokens.unwrap_or(0)
      end

      for choice in event.choices.unwrap_or([])
        content = choice.delta.unwrap_or(Piece(content: none)).content.unwrap_or("")
        if content != ""
          if first_ns < 0
            first_ns = Time.monotonic_ns()
          end

          parts = parts.push(content)
        end
      end
    end
  end

  error("unreachable")
end

def last_newline(bytes: Bytes) -> Int
  i = bytes.size - 1
  while i >= 0
    return i if bytes[i] == 10

    i = i - 1
  end

  -1
end

# --- the numbers

def summary(settings: Settings, outcomes: List[Outcome], wall: Float) -> RunResult
  samples = outcomes.flat_map do |o| o.samples end
  failures = outcomes.flat_map do |o| o.failures end
  seconds_list = samples.map do |s| s.seconds end
  latencies = seconds_list.sort
  tokens = samples.reduce(0) do |acc, s| acc + s.completion_tokens end
  prompts = samples.reduce(0) do |acc, s| acc + s.prompt_tokens end
  result = RunResult(
    concurrency: settings.concurrency,
    requests: samples.size,
    failures: failures.size,
    wall_s: wall,
    req_per_s: samples.size.to_f() / wall,
    gen_tok_per_s: tokens.to_f() / wall,
    completion_tokens: tokens,
    prompt_tokens: prompts,
    p50_s: percentile(latencies, 0.5),
    p95_s: percentile(latencies, 0.95),
  )

  if settings.stream
    first_list = samples.map do |s| s.first_seconds end
    firsts = first_list.sort
    result = result.with(
      ttft_p50_s: JSON.Field.Value(percentile(firsts, 0.5)),
      ttft_p95_s: JSON.Field.Value(percentile(firsts, 0.95)),
    )
  end

  if !failures.empty?
    result = result.with(first_failure: JSON.Field.Value(failures[0]))
  end

  if settings.keep_texts
    result = result.with(texts: JSON.Field.Value(texts_of(samples)))
  end

  result
end

## The answers by request number, in order.
def texts_of(samples: List[Sample]) -> Map[String, String]
  ordered = samples.sort_by do |s| s.index end
  ordered.reduce({}) do |acc, s| acc.put(s.index.to_s, s.text) end
end

def percentile(sorted: List[Float], q: Float) -> Float
  return 0.0 if sorted.empty?

  position = (sorted.size - 1).to_f() * q
  low = position.floor()
  high = [low + 1, sorted.size - 1].min.unwrap!()
  sorted[low] + (sorted[high] - sorted[low]) * (position - low.to_f())
end

## The checks of the HTTP API that every engine must pass: `api_test.agc` runs them against `server.agc` (llama.cpp) and
## `api_ml_test.agc` against `server_ml.agc` (the transformers of ml). A server and its log are the caller's.

import HTTP from "std/http"

TIMEOUT_MS = 120_000

## Every check, as test cases for the server on `port`.
def tests(port: Int) -> List[Test.Case]
  [
    Test.test("health") do check_health(port) end,
    Test.test("chat is OpenAI shaped and greedy is repeatable") do check_chat(port) end,
    Test.test("seeded sampling is repeatable") do check_seeded(port) end,
    Test.test("stream chunks add up to the greedy answer") do check_stream_chunks(port) end,
    Test.test("stream keeps multibyte characters whole") do check_multibyte(port) end,
    Test.test("stream of a refused request is 400") do check_refused_stream(port) end,
    Test.test("clients that leave free their slots") do check_leavers(port) end,
    Test.test("bad requests are 400") do check_bad_requests(port) end,
  ]
end

## The status of a request whose only message has `role`.
def role_status(port: Int, role: String) -> Result[Int]
  status_of(post(port, [Message(role: role, content: "hi")], {}))
end

def free_port() -> Result[Int]
  listener = try TCP.listen("127.0.0.1", 0)
  port = TCP.local_port(listener)
  TCP.close_listener(listener)
  ok(port)
end

## Waits for `/health`, and fails when the server exits first.
def wait_ready(server: Process, port: Int, log: String) -> Result[Void]
  for _ in 0...START_ATTEMPTS
    exited = Process.wait(server, 1)
    return error("the server exited with #{exited.unwrap!} (see #{log})") if exited.ok?

    health = HTTP.get_response("http://127.0.0.1:#{port}/health", HTTP.ClientOptions(timeout_ms: 2000))
    return ok() if health.ok? and health.unwrap!.status == 200

    Task.sleep(300)
  end

  error("the server did not start (see #{log})")
end

private

START_ATTEMPTS = 200

MESSAGES = [
  Message(role: "system", content: "You are a helpful assistant."),
  Message(role: "user", content: "Name three colors."),
]

struct Message
  role: String
  content: String
end

struct Usage
  prompt_tokens: Int
  completion_tokens: Int
  total_tokens: Int
end

struct Choice
  message: Message
  finish_reason: String
end

struct Completion
  object: String
  choices: List[Choice]
  usage: Usage
end

struct Delta
  role: Optional[String]
  content: Optional[String]
end

struct ChunkChoice
  delta: Delta
  finish_reason: Optional[String]
end

struct Chunk
  id: String
  object: String
  choices: List[ChunkChoice]
  usage: Optional[Usage]
end

struct Reply
  status: Int
  content_type: String
  body: String
end

# --- HTTP

def send(method: String, url: String, body: String, options: HTTP.ClientOptions) -> Result[HTTP.Response]
  return HTTP.get_response(url, options) if method == "GET"

  HTTP.post_response(url, body.bytes, [HTTP.Header(name: "Content-Type", value: "application/json")], options)
end

def request(port: Int, method: String, path: String, body: String) -> Result[Reply]
  url = "http://127.0.0.1:#{port}#{path}"
  options = HTTP.ClientOptions(timeout_ms: TIMEOUT_MS, read_timeout_ms: TIMEOUT_MS, max_body_bytes: 8_388_608)
  response = try send(method, url, body, options)
  types = HTTP.header_values(response.headers, "content-type")
  ok(Reply(status: response.status, content_type: first_of(types), body: try HTTP.text(response.body, [])))
end

def first_of(values: List[String]) -> String
  return "" if values.empty?

  values[0]
end

def payload(messages: List[Message], extra: Map[String, JSON.Value]) -> String
  JSON.encode(JSON.object(extra.put("messages", JSON.from(messages))))
end

def post(port: Int, messages: List[Message], extra: Map[String, JSON.Value]) -> Result[Reply]
  request(port, "POST", "/v1/chat/completions", payload(messages, extra))
end

def post_raw(port: Int, body: String) -> Result[Reply] = request(port, "POST", "/v1/chat/completions", body)

def status_of(reply: Result[Reply]) -> Result[Int]
  r = try reply
  ok(r.status)
end

def chat(port: Int, extra: Map[String, JSON.Value]) -> Result[Completion]
  reply = try post(port, MESSAGES, extra)
  try Test.eq(reply.status, 200)
  JSON.decode(reply.body, Completion)
end

def stream(port: Int, messages: List[Message], extra: Map[String, JSON.Value]) -> Result[Reply]
  post(port, messages, extra.put("stream", JSON.from(true)))
end

def answer(completion: Completion) -> String = completion.choices[0].message.content

## The `data:` payloads of a stream body, in order.
def events(body: String) -> Result[List[String]]
  blocks = body.split("\n\n").select do |b| b != "" end
  for block in blocks
    try Test.assert(block.start_with?("data: "), body)
  end

  ok(blocks.map do |b| b.slice(6, b.length - 6) end)
end

## The text of the delta of the chunk before the usage chunk, as the server wrote it.
def final_delta(data: List[String]) -> Result[String]
  chunk = try JSON.parse(data[data.size - 3])
  choice = try JSON.at(try JSON.get(chunk, "choices"), 0)
  ok(JSON.encode(try JSON.get(choice, "delta")))
end

## The chunks of a stream: its events without the final `[DONE]`.
def decode_chunks(data: List[String]) -> Result[List[Chunk]]
  chunks: List[Chunk] = []
  for e in data.take(data.size - 1)
    chunks = chunks.push(try JSON.decode(e, Chunk))
  end

  ok(chunks)
end

def greedy(tokens: Int) -> Map[String, JSON.Value] = {"max_tokens": JSON.from(tokens), "temperature": JSON.from(0.0)}

# --- the tests

def check_health(port: Int) -> Result[Void]
  reply = try request(port, "GET", "/health", "")
  try Test.eq(reply.status, 200)
  Test.eq(try JSON.decode(reply.body, Map[String, String]), {"status": "ok"})
end

def check_chat(port: Int) -> Result[Void]
  first = try chat(port, greedy(16))
  try Test.eq(first.object, "chat.completion")
  try Test.eq(first.choices[0].message.role, "assistant")
  try Test.assert(first.usage.completion_tokens <= 16, "completion_tokens #{first.usage.completion_tokens}")
  try Test.assert(["stop", "length"].include?(first.choices[0].finish_reason), first.choices[0].finish_reason)
  try Test.eq(first.usage.total_tokens, first.usage.prompt_tokens + first.usage.completion_tokens)
  second = try chat(port, greedy(16))
  Test.eq(answer(first), answer(second))
end

def check_seeded(port: Int) -> Result[Void]
  extra = {"max_tokens": JSON.from(16), "temperature": JSON.from(0.8), "seed": JSON.from(7)}
  a = try chat(port, extra)
  b = try chat(port, extra)
  Test.eq(answer(a), answer(b))
end

def check_stream_chunks(port: Int) -> Result[Void]
  whole = try chat(port, greedy(24))
  extra = greedy(24).put("stream_options", JSON.from({"include_usage": true}))
  reply = try stream(port, MESSAGES, extra)
  try Test.eq(reply.status, 200)
  try Test.assert(reply.content_type.start_with?("text/event-stream"), reply.content_type)
  data = try events(reply.body)
  try Test.eq(data.last, "[DONE]")
  chunks = try decode_chunks(data)
  try Test.assert(chunks.all? do |c| c.object == "chat.completion.chunk" end, "an object that is not a chunk")
  ids = chunks.map do |c| c.id end
  try Test.eq(ids.uniq.size, 1)
  # first chunk: the role; then content pieces; then the finish reason; then the usage chunk (no choices)
  first = chunks[0].choices[0]
  last = chunks[chunks.size - 2].choices[0]
  usage = chunks[chunks.size - 1]
  try Test.eq(first.delta.role, some("assistant"))
  try Test.assert(first.finish_reason.none?, "the first chunk has a finish_reason")
  try Test.eq(try final_delta(data), "{}")
  try Test.eq(last.finish_reason, some(whole.choices[0].finish_reason))
  try Test.eq(usage.choices.size, 0)
  try Test.eq(usage.usage, some(whole.usage))
  middle = chunks.drop(1).take(chunks.size - 3).map do |c| c.choices[0] end
  for m in middle
    try Test.assert(m.finish_reason.none? and !m.delta.content.unwrap_or("").empty?, "a middle chunk is not content")
  end

  parts = middle.map do |m| m.delta.content.unwrap_or("") end
  text = parts.join("")
  Test.eq(text, answer(whole))
end

## Emoji often span several tokens: every piece must still be valid UTF-8 (the body decodes and the pieces have no
## replacement character) and the pieces must add up to the non-streaming text.
def check_multibyte(port: Int) -> Result[Void]
  prompt = [Message(role: "user", content: "Write 3 lines using rare emoji such as 🫠 🪿.")]
  whole = try post(port, prompt, greedy(60))
  reply = try stream(port, prompt, greedy(60))
  data = try events(reply.body)
  chunks = try decode_chunks(data)
  pieces = chunks.map do |c| c.choices[0].delta.content.unwrap_or("") end
  text = pieces.join("")
  try Test.assert(!text.include?("�"), text)
  Test.eq(text, (try JSON.decode(whole.body, Completion)).choices[0].message.content)
end

def long_prompt() -> List[Message] = [Message(role: "user", content: "word " * 3000)]

def check_refused_stream(port: Int) -> Result[Void]
  reply = try stream(port, long_prompt(), {})
  Test.eq(reply.status, 400)
end

## More abandoned streams than slots (4), each asking for far more than it reads. If the engine kept decoding for
## them, the request after them would wait minutes for a slot.
def check_leavers(port: Int) -> Result[Void]
  body = JSON.encode(
    JSON.object({
      "messages": JSON.from(MESSAGES),
      "stream": JSON.from(true),
      "max_tokens": JSON.from(900),
      "temperature": JSON.from(0.0),
    }),
  )

  for _ in 0...6
    try leave_after_first_event(port, body)
  end

  started = Time.monotonic_ms()
  completion = try chat(port, greedy(8))
  try Test.assert(Time.monotonic_ms() - started < 60_000, "the request waited for a slot")
  try Test.assert(completion.usage.completion_tokens > 0, "no tokens")
  try Test.eq((try request(port, "GET", "/health", "")).status, 200)
  ok()
end

def leave_after_first_event(port: Int, body: String) -> Result[Void]
  socket = try TCP.connect("127.0.0.1", port, TIMEOUT_MS)
  head = (
    "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" +
    "Content-Length: #{body.bytes.size}\r\n\r\n"
  )

  got = read_after_send(socket, head + body)
  TCP.close(socket)
  got
end

def read_after_send(socket: TCP.Socket, text: String) -> Result[Void]
  try TCP.send(socket, text, TIMEOUT_MS)
  read_first_event(socket)
end

def read_first_event(socket: TCP.Socket) -> Result[Void]
  seen = ""
  while true
    parts = seen.split("\r\n\r\n")
    return ok() if parts.size > 1 and parts.drop(1).join("").include?("data: {")

    bytes = try TCP.recv_bytes(socket, 4096, TIMEOUT_MS)
    return error("the server closed before the first event") if bytes.empty?

    seen = seen + bytes.scrub()
  end

  ok()
end

def check_bad_requests(port: Int) -> Result[Void]
  try Test.eq(try status_of(post(port, [], {})), 400)
  try Test.eq(try status_of(post_raw(port, "{\"nope\": 1}")), 400)
  try Test.eq(try status_of(post(port, long_prompt(), {})), 400)
  for bad in [0, -1, -5]
    extra = {"max_tokens": JSON.from(bad)}
    try Test.eq(try status_of(post(port, MESSAGES, extra)), 400)
    try Test.eq(try status_of(stream(port, MESSAGES, extra)), 400)
  end

  Test.eq((try request(port, "GET", "/health", "")).status, 200)
end

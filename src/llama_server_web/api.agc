## The OpenAI-shaped routes, on Bond: `POST /v1/chat/completions` (one JSON answer, or server-sent events with
## `"stream": true`) and `GET /health`.

import Bond from "pkg/bond/bond"
import Contract from "../llama_server/contract"
import Numbers from "../llama_server/numbers"

## What the routes share: the engine and a table with the request counter.
struct Api
  engine: Contract.Handle
  counters: ATS[String, Int]
end

def new_api(engine: Contract.Handle) -> Api
  counters: ATS[String, Int] = ATS.new()
  Api(engine: engine, counters: counters)
end

def app(api: Api) -> Bond.App
  (
    Bond.app()
    |> Bond.get("/health", &health)
    |> Bond.post("/v1/chat/completions") do |conn| chat(api, conn) end
  )
end

private

DEFAULT_MAX_TOKENS = 128
ANSWER_TIMEOUT_MS = 600_000
# The events channel to Bond holds a few chunks; a client that stops reading for this long is dropped.
EVENT_BUFFER = 16
EVENT_SEND_TIMEOUT_MS = 10_000
PIECE_WAIT_MS = 60_000

struct StreamOptions
  include_usage: Optional[Bool] = none
end

struct ChatRequest
  messages: List[Contract.Message]
  max_tokens: Optional[Int] = none
  temperature: Optional[Float] = none
  seed: Optional[Int] = none
  stream: Optional[Bool] = none
  stream_options: Optional[StreamOptions] = none
end

struct ReplyMessage
  role: String
  content: String
end

struct Choice
  index: Int
  message: ReplyMessage
  finish_reason: String
end

struct Usage
  prompt_tokens: Int
  completion_tokens: Int
  total_tokens: Int
end

struct ChatResponse
  id: String
  object: String
  created: Int
  model: String
  choices: List[Choice]
  usage: Usage
end

# What a `chat.completion.chunk` carries: a key that is absent stays out of the JSON (the final delta is `{}`),
# `finish_reason` is `null` until the last chunk.
struct Delta
  role: JSON.Field[String] = JSON.Field.Absent
  content: JSON.Field[String] = JSON.Field.Absent
end

struct ChunkChoice
  index: Int
  delta: Delta
  finish_reason: JSON.Field[String] = JSON.Field.Null
end

struct Chunk
  id: String
  object: String
  created: Int
  model: String
  choices: List[ChunkChoice]
  usage: JSON.Field[Usage] = JSON.Field.Absent
end

# What the task that turns engine pieces into events needs; it cannot take the `Conn`.
struct Pump
  reply: Channel[Contract.GenResult]
  events: Channel[Bytes]
  first: Contract.GenResult
  id: String
  created: Int
  model: String
  include_usage: Bool
end

def health(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.json(conn, 200, JSON.from({"status": "ok"})))

def chat(api: Api, conn: Bond.Conn) -> Result[Bond.Conn]
  body = try Bond.json_body(conn, ChatRequest.codec)
  return Bond.bad_request("messages must not be empty") if body.messages.empty?

  max_tokens = body.max_tokens.unwrap_or(DEFAULT_MAX_TOKENS)
  return Bond.bad_request("max_tokens must be at least 1") if max_tokens < 1
  return Bond.bad_request("temperature must not be negative") if body.temperature.unwrap_or(1.0) < 0.0

  tokens = api.engine.prompt.call(body.messages)
  return Bond.bad_request(tokens.message) if not tokens.ok?

  stream = body.stream.unwrap_or(false)
  # A stream is a piece per token and the engine never waits, so the channel holds the whole answer.
  room = 1
  if stream
    room = Numbers.smaller(max_tokens, api.engine.n_ctx) + 2
  end

  reply: Channel[Contract.GenResult] = Channel.new(room)
  request = Contract.GenRequest(
    prompt: tokens.unwrap!,
    max_tokens: max_tokens,
    temperature: body.temperature.unwrap_or(1.0),
    seed: body.seed.unwrap_or(0),
    stream: stream,
    reply: reply,
  )

  case api.engine.requests.send(request, ANSWER_TIMEOUT_MS)
    ok(_) ->
      return stream_answer(api, conn, reply, wants_usage(body)) if stream

      answer(api, conn, reply)
    error(e) -> ok(Bond.halt(conn, 503, e.message))
  end
end

def wants_usage(body: ChatRequest) -> Bool
  case body.stream_options
    some(options) -> options.include_usage.unwrap_or(false)
    none -> false
  end
end

# The reader gives up (a timeout) by closing `reply`: the engine skips a request whose reply is closed.
def answer(api: Api, conn: Bond.Conn, reply: Channel[Contract.GenResult]) -> Result[Bond.Conn]
  case reply.recv(ANSWER_TIMEOUT_MS)
    ok(result) ->
      return ok(refused(conn, result)) if result.finish_reason == "error"

      ok(respond(api, conn, result))
    error(e) ->
      reply.close
      ok(Bond.halt(conn, 504, e.message))
  end
end

# A request's own fault is a 400, the engine's a 500.
def refused(conn: Bond.Conn, result: Contract.GenResult) -> Bond.Conn
  case result.fault
    Contract.Fault.Client -> Bond.halt(conn, 400, result.failure)
    _ -> Bond.halt(conn, 500, result.failure)
  end
end

def respond(api: Api, conn: Bond.Conn, result: Contract.GenResult) -> Bond.Conn
  response = ChatResponse(
    id: "chatcmpl-#{api.counters.add("requests", 1)}",
    object: "chat.completion",
    created: Time.now_ms() / 1000,
    model: api.engine.model_name,
    choices: [
      Choice(
        index: 0,
        message: ReplyMessage(role: "assistant", content: result.text),
        finish_reason: result.finish_reason,
      ),
    ],
    usage: Usage(
      prompt_tokens: result.prompt_tokens,
      completion_tokens: result.completion_tokens,
      total_tokens: result.prompt_tokens + result.completion_tokens,
    ),
  )

  Bond.json_as(conn, 200, ChatResponse.codec, response)
end

# Waits for the first piece, so a request the engine refuses is still a 400 (the head of a stream cannot be
# taken back), then hands the rest to a task: the route returns and Bond sends each event as it is made.
def stream_answer(
  api: Api,
  conn: Bond.Conn,
  reply: Channel[Contract.GenResult],
  include_usage: Bool,
) -> Result[Bond.Conn]
  case reply.recv(ANSWER_TIMEOUT_MS)
    ok(first) ->
      return ok(refused(conn, first)) if first.finish_reason == "error"

      events: Channel[Bytes] = Channel.new(EVENT_BUFFER)
      pump = Pump(
        reply: reply,
        events: events,
        first: first,
        id: "chatcmpl-#{api.counters.add("requests", 1)}",
        created: Time.now_ms() / 1000,
        model: api.engine.model_name,
        include_usage: include_usage,
      )

      # Owning: the task owns `reply` and `events`, so a crash of the pump closes them and the response ends.
      Task.spawn_owning(&pump_events, pump)
      ok(Bond.sse(conn, events))
    error(e) ->
      reply.close
      ok(Bond.halt(conn, 504, e.message))
  end
end

# Turns the engine's pieces into `chat.completion.chunk` events: the role first, a content chunk per piece, then
# the finish reason (and the usage when asked) and `[DONE]`. When an event cannot be sent (the client left, or
# stopped reading) it closes `reply`, which makes the engine's next send fail and free the slot.
def pump_events(pump: Pump) -> Void
  if send_chunk(pump, Delta(role: JSON.Field.Value("assistant"), content: JSON.Field.Value("")), JSON.Field.Null)
    relay(pump, pump.first)
  end

  pump.reply.close
  pump.events.close
end

def relay(pump: Pump, first: Contract.GenResult) -> Void
  piece = first
  while true
    if piece.finish_reason == "error"
      # The head went out as a 200: all that is left is an error event, and no `[DONE]`.
      send_error(pump, piece.failure)
      return
    end

    if not piece.text.empty? and not send_chunk(pump, Delta(content: JSON.Field.Value(piece.text)), JSON.Field.Null)
      return
    end

    break if not piece.finish_reason.empty?

    case pump.reply.recv(PIECE_WAIT_MS)
      ok(next_piece) -> piece = next_piece
      error(_) ->
        # The engine stalled (or was cancelled): say so, since the head already went out as a 200.
        send_error(pump, "the engine did not answer")
        return
    end
  end

  return if not send_chunk(pump, Delta(), JSON.Field.Value(piece.finish_reason))

  return if pump.include_usage and not send_usage(pump, piece)

  _ = pump.events.send(Bond.sse_event("[DONE]"), EVENT_SEND_TIMEOUT_MS)
end

def send_error(pump: Pump, message: String) -> Void
  failure = JSON.from({"error": {"message": message, "type": "server_error"}})
  _ = pump.events.send(Bond.sse_event(JSON.encode(failure)), EVENT_SEND_TIMEOUT_MS)
end

def send_chunk(pump: Pump, delta: Delta, finish: JSON.Field[String]) -> Bool
  chunk = Chunk(
    id: pump.id,
    object: "chat.completion.chunk",
    created: pump.created,
    model: pump.model,
    choices: [ChunkChoice(index: 0, delta: delta, finish_reason: finish)],
  )

  pump.events.send(Bond.sse_event(JSON.encode(chunk)), EVENT_SEND_TIMEOUT_MS).ok?
end

# The usage chunk of `stream_options.include_usage`: no choices, only the counts.

def send_usage(pump: Pump, last: Contract.GenResult) -> Bool
  usage = Usage(
    prompt_tokens: last.prompt_tokens,
    completion_tokens: last.completion_tokens,
    total_tokens: last.prompt_tokens + last.completion_tokens,
  )

  chunk = Chunk(
    id: pump.id,
    object: "chat.completion.chunk",
    created: pump.created,
    model: pump.model,
    choices: [],
    usage: JSON.Field.Value(usage),
  )

  pump.events.send(Bond.sse_event(JSON.encode(chunk)), EVENT_SEND_TIMEOUT_MS).ok?
end

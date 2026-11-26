## What the web side knows of an engine: a request channel, how to turn a conversation into token ids, and the limits.
##
## An engine is a task that reads `GenRequest`s from the channel of its `Handle` and answers each on the request's own
## reply channel: one `GenResult`, or, when `stream` is on, a piece per step and a last one with the finish reason.
## `engine.agc` is the one on llama.cpp, `ml_engine.agc` the one on the transformers of ml.

## One turn of a conversation.
struct Message
  role: String
  content: String
end

## A request already tokenized by the route; the answer goes back on `reply`.
struct GenRequest
  prompt: List[Int]
  max_tokens: Int
  temperature: Float
  seed: Int
  stream: Bool = false
  reply: Channel[GenResult]
end

## Whose fault a refusal is: the request's (a 400) or the engine's (a 500).
enum Fault
  None
  Client
  Internal
end

## The whole answer, or in a stream the text of one piece (`finish_reason` is "" until the last one, whose `text` is
## empty). `completion_tokens` counts the tokens sampled so far in a piece.
struct GenResult
  text: String
  prompt_tokens: Int
  completion_tokens: Int
  finish_reason: String
  failure: String
  fault: Fault = Fault.None
end

## What the routes hold of a running engine. `n_ctx` bounds how many pieces a stream can hold, so the engine never
## waits for a slow reader.
struct Handle
  model_name: String
  n_ctx: Int
  requests: Channel[GenRequest]
  prompt: Fn[List[Message], Result[List[Int]]]
end

## The answer of a request that cannot run.
def refusal(message: String, fault: Fault) -> GenResult
  GenResult(text: "", prompt_tokens: 0, completion_tokens: 0, finish_reason: "error", failure: message, fault: fault)
end

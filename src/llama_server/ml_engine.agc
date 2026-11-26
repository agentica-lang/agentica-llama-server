## The engine on the transformers of ml: a Qwen3 or Qwen2.5 model (a Hugging Face folder or a GGUF file) with a
## key-value cache, one sequence at a time.
##
## One task owns the generator and takes the requests from the channel in order, each to its end: ml has no batched
## decode yet (ml#90), so concurrent clients queue. The reply is the same as the engine of llama.cpp: one `GenResult`,
## or, for a stream, a piece per token that completes a character and a last one with the finish reason. The engine
## never waits on a stream's channel, and a send that fails (the client left) ends the sequence.

import Contract from "contract"
import Numbers from "numbers"
import Bpe from "pkg/transformers/tokenizer/bpe"
import Chat from "pkg/transformers/chat"
import Generate from "pkg/transformers/generate"
import Qwen3 from "pkg/transformers/qwen3"
import Sample from "pkg/transformers/sample"
import Tensor from "pkg/tensor/tensor"

## A model, its tokenizer and the generator that decodes it.
struct Loaded
  model: Qwen3.Qwen3
  generator: Generate.Generator
  tokenizer: Bpe.ByteLevelBpe
  ## The ids the tokenizer has: the model may have more (padding), which a step never answers.
  vocab: Int
  ## The ids that end an answer: `<|im_end|>` and `<|endoftext|>`.
  stop: List[Int]
  ## The positions of a prompt and its answer together.
  context: Int
end

## The tokens that were sampled and are not text yet, and the text that they complete.
struct Piece
  text: String
  held: List[Int]
end

## Loads the model at `path` (a folder with `config.json`, `model.safetensors` and `tokenizer.json`, or a `.gguf`
## file) on `backend`, with weights of `weights` dtype. `n_ctx` caps the positions a request can use.
def load(path: String, backend: Tensor.Backend, weights: Tensor.Dtype, n_ctx: Int) -> Result[Loaded]
  if not Tensor.available(backend)
    return error("the backend #{backend} is not available: ml's ggml module is not built (docs/ml.md)")
  end

  return error("--ctx must be at least 2") if n_ctx < 2

  model = try Qwen3.open(path, backend, weights)
  tokenizer = try open_tokenizer(path)
  generator = try Generate.open(model, tokenizer.pieces.size)
  ok(
    Loaded(
      model: model,
      generator: generator,
      tokenizer: tokenizer,
      vocab: tokenizer.pieces.size,
      stop: try stop_ids(tokenizer),
      context: Numbers.smaller(n_ctx, model.config.max_position_embeddings),
    ),
  )
end

## What the routes hold of the engine of `loaded`.
def handle(loaded: Loaded, requests: Channel[Contract.GenRequest], name: String) -> Contract.Handle
  Contract.Handle(
    model_name: name,
    n_ctx: loaded.context,
    requests: requests,
    prompt: ->(messages: List[Contract.Message]) { prompt_of(loaded, messages) },
  )
end

## Runs until the process ends.
def run(loaded: Loaded, requests: Channel[Contract.GenRequest]) -> Result[Void]
  while true
    case requests.recv(IDLE_WAIT_MS)
      ok(request) -> answer(loaded, request)
      error(_) -> nil
    end
  end

  ok()
end

## The text that `held` completes. A character can be split between tokens, so while the text ends in a replacement
## character the tokens wait for the next one; at `MAX_HELD` of them the bytes are broken and the replacements stay.
def whole_text(tokenizer: Bpe.ByteLevelBpe, held: List[Int]) -> Result[Piece]
  text = try Bpe.decode(tokenizer, held)
  return ok(Piece(text: "", held: held)) if text.end_with?(String.from_code(65533)) and held.size < MAX_HELD

  ok(Piece(text: text, held: []))
end

private

IDLE_WAIT_MS = 100
REPLY_TIMEOUT_MS = 5000
## A character is at most 4 bytes, and a token is at least one: after this many tokens held, the bytes are broken.
MAX_HELD = 4
SEED_MODULUS = 2147483646
## A request whose reader left is dropped before its first step and then every this many tokens.
CHECK_EVERY = 4

## The id that a step chose, the cache after it and the state of the draws.
struct Next
  id: Int
  cache: Generate.Cache
  state: Int
end

def open_tokenizer(path: String) -> Result[Bpe.ByteLevelBpe]
  return Bpe.open_gguf(path) if path.end_with?(".gguf")

  Bpe.open("#{path}/tokenizer.json")
end

def stop_ids(tokenizer: Bpe.ByteLevelBpe) -> Result[List[Int]]
  ends = try Bpe.encode(tokenizer, "<|im_end|>")
  return error("the tokenizer has no <|im_end|> token") if ends.size != 1

  ids = ends
  found = try Bpe.encode(tokenizer, "<|endoftext|>")
  if found.size == 1
    ids = ids.push(found[0])
  end

  ok(ids)
end

def prompt_of(loaded: Loaded, messages: List[Contract.Message]) -> Result[List[Int]]
  turns = messages.map do |m| Chat.Message(role: m.role, content: m.content) end
  text = try Chat.apply(loaded.model.config.model_type, turns)
  Bpe.encode(loaded.tokenizer, text)
end

# Temperature 0 (or less) is greedy and stays in the graph; above it the draw is on the host.
def sampling_of(request: Contract.GenRequest) -> Result[Optional[Sample.Sampling]]
  return ok(none) if request.temperature <= 0.0

  seed = (request.seed % SEED_MODULUS + SEED_MODULUS) % SEED_MODULUS
  sampling = Sample.Sampling(temperature: request.temperature, seed: seed)
  try Sample.check(sampling)
  ok(some(sampling))
end

def answer(loaded: Loaded, request: Contract.GenRequest) -> Void
  room = loaded.context - request.prompt.size
  if request.prompt.empty? or room < 1
    refuse(request, "the prompt does not fit in a context of #{loaded.context} tokens", Contract.Fault.Client)
    return
  end

  case sampling_of(request)
    ok(sampling) -> decode(loaded, request, sampling, Numbers.smaller(request.max_tokens, room))
    error(e) -> refuse(request, e.message, Contract.Fault.Client)
  end
end

# The sequence of one request: a step per token until a stop id or the limit.
def decode(loaded: Loaded, request: Contract.GenRequest, sampling: Optional[Sample.Sampling], limit: Int) -> Void
  cache = Generate.start()
  feed = request.prompt
  state = 0
  case sampling
    some(s) -> state = Sample.start(s)
    none -> nil
  end

  generated = 0
  held: List[Int] = []
  parts: List[String] = []
  reason = "length"
  while generated < limit
    # The reader of a whole answer may have left: a stream finds out when its send fails.
    if generated % CHECK_EVERY == 0 and request.reply.closed?
      Generate.finish(cache)
      return
    end

    case next_token(loaded, cache, feed, sampling, state)
      error(e) ->
        refuse(request, e.message, Contract.Fault.Internal)
        return
      ok(drawn) ->
        cache = drawn.cache
        state = drawn.state
        if loaded.stop.include?(drawn.id)
          reason = "stop"
          break
        end

        generated += 1
        feed = [drawn.id]
        piece = Piece(text: "", held: held)
        case whole_text(loaded.tokenizer, held.push(drawn.id))
          ok(found) -> piece = found
          error(e) ->
            Generate.finish(cache)
            refuse(request, e.message, Contract.Fault.Internal)
            return
        end

        held = piece.held
        if request.stream and not piece.text.empty?
          delta = Contract.GenResult(
            text: piece.text,
            prompt_tokens: 0,
            completion_tokens: generated,
            finish_reason: "",
            failure: "",
          )

          if not request.reply.send(delta, 0).ok?
            Generate.finish(cache)
            return
          end
        end

        parts = parts.push(piece.text)
    end
  end

  Generate.finish(cache)
  finish(request, parts.join(""), generated, reason)
end

# The id after `feed`: the largest logit (the pick runs in the graph), or a draw among the largest logits. A
# failed step
# has closed the cache it was given.
def next_token(
  loaded: Loaded,
  cache: Generate.Cache,
  feed: List[Int],
  sampling: Optional[Sample.Sampling],
  state: Int,
) -> Result[Next]
  case sampling
    some(s) ->
      top = try Generate.step_top(loaded.generator, cache, feed, Sample.window(s, loaded.vocab))
      case Sample.pick_top(top.ids, top.logits, s, state)
        ok(drawn) -> return ok(Next(id: drawn.id, cache: top.cache, state: drawn.state))
        error(e) ->
          Generate.finish(top.cache)
          return error(e.message)
      end

    none -> nil
  end

  picked = try Generate.step(loaded.generator, cache, feed)
  ok(Next(id: picked.id, cache: picked.cache, state: state))
end

def finish(request: Contract.GenRequest, text: String, generated: Int, reason: String) -> Void
  shown = text
  wait = REPLY_TIMEOUT_MS
  if request.stream
    shown = ""
    wait = 0
  end

  result = Contract.GenResult(
    text: shown,
    prompt_tokens: request.prompt.size,
    completion_tokens: generated,
    finish_reason: reason,
    failure: "",
  )

  _ = request.reply.send(result, wait)
end

def refuse(request: Contract.GenRequest, message: String, fault: Contract.Fault) -> Void
  _ = request.reply.send(Contract.refusal(message, fault), 0)
end

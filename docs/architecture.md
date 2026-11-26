# Architecture

The [Bond](https://github.com/agentica-lang/bond) web framework in front of llama.cpp, called through the Agentica FFI
(no C code). Tested with Agentica 0.38.0 (CI) and Bond 0.15.1.

## How it works

- [src/llama_server/llama.agc](../src/llama_server/llama.agc): bindings for the part of `llama.h` a server needs (backend init, model load, context, vocab,
  tokenize, chat template, batch, decode, sampler chain, token to piece, free). `llama_decode` and the model load are
  `compute def`. The `llama_*_params` structs and `llama_batch` are FFI structs passed by value.
- [src/llama_server/engine.agc](../src/llama_server/engine.agc): one task owns the context and does continuous batching. Requests arrive on a `Channel`; each step
  puts the next token of every active sequence (or the whole prompt of a new one) into one batch, up to
  `--parallel` sequences (each its own `seq_id`, its own `n_ctx / parallel` share of the KV cache), decodes once,
  samples every sequence with llama.cpp's sampler chain in C, and answers on a per-request channel. A freed slot takes the
  next waiting request in the next step.
- [src/llama_server/contract.agc](../src/llama_server/contract.agc): what the routes know of an engine: `GenRequest` and
  `GenResult`, and a `Handle` (a request channel, the model name, the context and a function from messages to token
  ids). An engine is a task that serves that channel. `engine.agc` is the one above;
  [src/llama_server/ml_engine.agc](../src/llama_server/ml_engine.agc) is the one on ml's transformers
  ([ml.md](ml.md)).
- [src/llama_server_web/api.agc](../src/llama_server_web/api.agc), [server.agc](../server.agc): Bond routes `POST /v1/chat/completions` (OpenAI shape:
  `messages`, `max_tokens`, `temperature`, `seed`, `stream`, `stream_options.include_usage`) and `GET /health`.
  A plain request is answered with `Bond.json_as(conn, 200, ChatResponse.codec, response)`.

## The streaming path

`"stream": true` answers `text/event-stream` with `Bond.sse`, in the shape `llama-server` and OpenAI emit: a chunk with
`delta.role`, a chunk with `delta.content` per piece of text, a chunk with `finish_reason` and an empty `delta`, a usage
chunk when `stream_options.include_usage` is on, then `data: [DONE]`.

```text
client <-SSE- Bond (std/http) <- events: Channel[Bytes] <- pump task <- reply: Channel[GenResult] <- engine task
```

- **The engine sends each token's text as soon as it is sampled**, on the request's own `reply` channel, as a
  `GenResult` with an empty `finish_reason`; the last one carries the finish reason and the counts. It sends with a
  timeout of 0: it never waits for a reader. The route sizes the channel for the whole answer
  (`min(max_tokens, n_ctx) + 2`), so a reader that keeps up never sees it full.
- **UTF-8 stays whole.** A character can be split between tokens (an emoji often is). The engine keeps the bytes of an
  unfinished character in the sequence (`held`) and sends only whole characters, so every event is valid text. Bytes
  left over when the answer ends are dropped.
- **The route waits for the first piece** before it returns `Bond.sse`, so a request the engine refuses (a prompt that
  does not fit a slot) is still a `400` and the time to first token is real. It then starts the `pump` task and returns:
  the `Conn` is gone once the handler returns, so the task gets the channels and the ids, not the `Conn`.
- **The pump** turns pieces into chunk events, sends them to Bond's `events` channel with a timeout, and closes it at the
  end, which ends the HTTP body. It runs with `Task.spawn_owning`, so it owns `reply` and `events`: if it crashes, both
  close and the response ends instead of hanging. The channel holds the whole answer, so the engine's send fails only
  when the pump closed `reply`.
- **A client that leaves.** Bond closes `events` when the connection ends, so the pump's next `send` fails; the pump
  closes `reply`, the engine's next send for that sequence fails, and the engine frees the slot (clears its KV cells and
  closes the sampler) instead of decoding for nobody. The cost of leaving is one more token. A client that stops
  reading, but keeps the connection open, is noticed only when Bond's writer blocks (the pump's send then times out
  after 10 s); the kernel's socket buffers can hold a short answer whole, so such a client can finish its answer
  without ever being noticed. This was not measured.
- A failure after the head went out (a decode error, or an engine that gives no piece for 60 s) cannot change the
  status: the pump sends one `data: {"error": ...}` event and ends the stream without `[DONE]`.
- `max_tokens` below 1 is a `400` on both paths (a stream's channel size comes from it).

## Files

`src/llama_server/llama.agc`, `src/llama_server/engine.agc`, `src/llama_server_web/api.agc` and `server.agc` are described above. The source layout and its import rule are in the README.

```text
agentica.toml, agentica.lock   Bond pinned by tag; [native.llama] and [native.ggml]
server.agc, server_ml.agc      the programs (wiring): llama.cpp, ml
src/llama_server/              the domain: contract.agc, engine.agc, llama.agc (FFI), ml_engine.agc, numbers.agc, cli.agc and
                               ml_cli.agc (the flags, `std/option_parser`)
src/llama_server_web/          HTTP: api.agc (the Bond routes)
smoke.agc                      one sequence, to check the bindings
scripts/                       fetch.agc (the release, its sha256s and the model are recorded in llama-release and model), check_bindings.agc
bench/client.agc, run_all.agc  the load client and the comparison runner
bench/results/                 the JSON of every run behind the tables
tests/api_cases.agc            the end-to-end checks of the routes, streaming and a client that leaves, for any engine
tests/api_test.agc             runs them on server.agc; tests/api_ml_test.agc on server_ml.agc (tests/tiny_qwen3.agc writes its model)
tests/cli_test.agc             the flags: `--help`, a bad value, an unknown flag, a valid set (no model needed)
tests/bindings_test.agc, fetch_test.agc   the bindings check and the fetch program, tested from outside
```

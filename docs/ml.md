# The server on ml's transformers

`server_ml.agc` answers the same `POST /v1/chat/completions` (JSON or server-sent events) and `GET /health` as
`server.agc`, but the model runs on the transformers of [ml](https://github.com/agentica-lang/ml) (`transformers-0.6.0`,
pinned by tag in `agentica.toml`): Qwen3 and Qwen2.5, from a Hugging Face folder (`config.json`, `model.safetensors`,
`tokenizer.json`) or a GGUF file. The tokenizer and the chat template are ml's too. No llama.cpp library is loaded.

```sh
agentica install
agentica server_ml.agc --model ~/models/Qwen3-0.6B --backend ggml --port 8080
curl localhost:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":32,"stream":true}'
```

Options: `--model PATH` (required), `--name NAME` (the model name in the answers), `--backend ggml|vulkan|reference`
(default `ggml`), `--weights f32|f16` (`f16` needs a ggml backend), `--host`, `--port`, `--ctx N` (positions of a prompt
and its answer together, at most the model's). `--help` lists them.

## What it does and does not

- **One request at a time.** One engine task owns the generator and serves the requests in the order they arrive; the
  others wait in the queue. ml decodes one sequence per step (ml#90 plans the batched decode), so the aggregate tokens
  per second of many clients is that of one.
- **Streaming and usage** work as in `server.agc`: a piece per token that completes a character, then the finish
  reason, the usage chunk when `stream_options.include_usage` is on, and `[DONE]`. A client that leaves ends its
  sequence at the next token.
- **A request that waits can still be dropped.** A request whose reply channel is closed is skipped before its first
  step and then every 4 tokens, and the route closes the channel when its wait times out (600 s). Bond gives a handler no
  signal that its client left, so a plain request whose client leaves keeps its place until that timeout; a stream
  notices at its next token.
- **Errors:** a prompt that does not fit, a bad `temperature` (negative, or a positive one too small to use) or a role
  that the chat template does not know is a `400`; a failure of a step is a `500`. If the engine task crashes or cannot
  start, the process ends.
- **Sampling:** `temperature` 0 is greedy (the pick runs in the graph); above 0 the token is drawn on the host among the
  256 largest logits (ml's `Sample`), the same ids for the same `seed`. A request with no `seed` has seed 0, so it is deterministic too: the same prompt and
  `temperature` give the same text. `top_p` and `top_k` are not read from the
  request. `finish_reason` is `stop` at `<|im_end|>` or `<|endoftext|>` and `length` at `max_tokens` or the context.
- **Qwen3 thinks** unless the model's template says otherwise: the chat template is applied with thinking on, so the
  answer starts with a `<think>` block.

## The backends

`reference` is ml's pure Agentica backend: correct and very slow, the one the tests use. `ggml` and `vulkan` need ml's
ggml native module, which is optional: without it every run prints `warning: native module ggml not built` (and one
for torch, which this server never uses) and `--backend ggml` stops with "the backend ... is not available". Building the
module needs ggml's static libraries; see `tensor/README.md` of ml ("The ggml backend"). **CI runs only the reference
backend**: a run on `ggml` or `vulkan` is not verified by any test here.

## The two engines in one process

llama.cpp's `libggml.so` and ml's statically linked ggml must never load into the same process. `server_ml.agc`
imports nothing that calls llama.cpp, the natives load at the first call, and `tests/api_ml_test.agc` checks that the
server process maps no `libllama` and no `libggml`.

## Measuring tokens per second

`bench/client.agc` is a closed-loop client for any OpenAI-style server, `server.agc` or `server_ml.agc`: one task per
concurrent client, each with its own connection, sending requests back to back. It prints one JSON line with the
**aggregate** generated tokens per second (`gen_tok_per_s`: all the clients together, over the wall time), requests per
second, the latency percentiles, and, with `--stream`, the time to first token (`ttft_p50_s`, `ttft_p95_s`: until the
first event with text).

```sh
agentica bench/client.agc --url http://127.0.0.1:8080 --concurrency 1 --requests 8 --max-tokens 64 --stream
for c in 1 2 4 8 16; do
  agentica bench/client.agc --url http://127.0.0.1:8080 --concurrency $c --requests $((c * 4)) --max-tokens 64 --stream
done
```

Add `--extra '{"temperature":0}'` for greedy answers. Run the client on the same box as the server, or on another one in the
same network. `tests/api_ml_test.agc` runs it against the tiny model.

What to expect from the two engines: `server.agc` batches its slots (`--parallel`), so its aggregate rate grows with the
clients until the CPU is full; `server_ml.agc` decodes one sequence at a time, so its aggregate rate stays at that of one
client and the time to first token of the later clients grows with the queue (the clients wait for the ones in front).
That gap is what the batched decode of ml#90 is for.

Use the same model on both: llama.cpp reads a GGUF, ml a GGUF or a Hugging Face folder.

## A fresh linux-arm64 box (AWS c8g)

1. Agentica: the release asset `agentica-0.38.0-linux-arm64.tar.gz` of
   [agentica-lang/agentica](https://github.com/agentica-lang/agentica/releases) (check it against the release's
   `SHA256SUMS`: `84efaabcf21ab578407a49e9e0fdb564316c2ba60fed3dcb2aeb8168804f9855`), extracted, with its `bin/` on `PATH`.
   `git` and a C compiler (`gcc`) are needed too.
2. This repository, then `agentica install` (Bond and ml's packages, by tag).
3. The model: for Qwen3-0.6B, `config.json`, `tokenizer.json` and `model.safetensors` of `Qwen/Qwen3-0.6B` into one
   folder.
4. **ml's ggml backend does not build on linux-arm64 yet** ([ml#349](https://github.com/agentica-lang/ml/issues/349)):
   `tensor/tools/build-engine.sh` is for Linux x86_64 only. The reference backend runs there but is far too slow to
   measure. When ml#349 is done, the build is the one of x86_64: a checkout of ml at the tag of `tensor` in
   `agentica.toml` with `git submodule update --init third_party/ggml`, then
   `eval "$(sh tensor/tools/build-engine.sh | grep '^export ')"` in the shell that runs the server (it prints the
   `C_INCLUDE_PATH` and `LIBRARY_PATH` that the native module needs; the module builds at the first run).
5. `agentica server_ml.agc --model ~/models/Qwen3-0.6B --backend ggml --weights f16 --ctx 2048`, and the client above.

`server.agc` (llama.cpp) is not supported on arm64: `scripts/fetch.agc` fetches the x86_64 llama.cpp release. A llama.cpp
number on c8g needs a llama.cpp build for arm64, which this repository does not fetch.

## inf2 (Neuron)

Not possible yet: Qwen3 does not run on `Backend.Xla`
([ml#243](https://github.com/agentica-lang/ml/issues/243): the transformer ops in the emitter and a decode with fixed
shapes). The engine here takes a backend from `--backend`, so a new one is a case of `backend_of` in `server_ml.agc`.

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
- **Sampling:** `temperature` 0 is greedy (the pick runs in the graph); above 0 the token is drawn on the host among the
  256 largest logits (ml's `Sample`), the same ids for the same `seed`. `top_p` and `top_k` are not read from the
  request. `finish_reason` is `stop` at `<|im_end|>` or `<|endoftext|>` and `length` at `max_tokens` or the context.
- **Qwen3 thinks** unless the model's template says otherwise: the chat template is applied with thinking on, so the
  answer starts with a `<think>` block.

## The backends

`reference` is ml's pure Agentica backend: correct and very slow, the one the tests use. `ggml` and `vulkan` need ml's
ggml native module, which is optional: without it every run prints `warning: native module ggml not built` (and one
for torch, which this server never uses) and `--backend ggml` stops with "the backend ... is not available". Building the
module needs ggml's static libraries; see `tensor/README.md` of ml ("The ggml backend").

## The two engines in one process

llama.cpp's `libggml.so` and ml's statically linked ggml must never load into the same process. `server_ml.agc`
imports nothing that calls llama.cpp, the natives load at the first call, and `tests/api_ml_test.agc` checks that the
server process maps no `libllama` and no `libggml`.

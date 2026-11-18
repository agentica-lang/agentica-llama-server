# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** needs Agentica 0.34.1 or later and Bond 0.15.1: the sources use `private` instead of `export`, the nested builtin names (`JSON.Field`, `HTTP.ServerOptions`) and the `Error` record of a failed Result, and are formatted with `agentica fmt` (implicit returns, guards, one-line defs). `agentica.toml` names the oldest Agentica it needs. CI tests with Agentica 0.34.1. The request and response codecs are `ChatRequest.codec` and `ChatResponse.codec`.
- llama.cpp v1.0.0, build b12359 (was b12012), the prebuilt Linux x86_64 CPU release, sha256-checked: the context parameters follow its new layout, and the manifest names `libllama.so.1` and `libggml.so.1`. v1.0.0 removes the deprecated functions of `llama.h` and `defrag_thold`; the server called none of them. The headers of the same build are fetched for the bindings check.
- **Breaking:** the scripts are Agentica programs. `agentica scripts/fetch.agc llama|headers|model|all` replaces `scripts/fetch-llama.sh`, `fetch-headers.sh` and `fetch-model.sh`; `make fetch` runs `all`. The llama.cpp libraries are extracted into `native/linux/` (no `deps/llama.cpp` and links), the release is `scripts/llama-release` (the tag and the sha256 of the archive and of each header; the headers are checked before they are used) and the default model is `scripts/model`, and the benchmark runs `native/linux/llama-server`. The downloads follow redirects, are taken in pieces (a model is larger than the 256 MiB that `HTTP.download` writes) and are sha256-checked before they take their name.

### Added

- `make check-bindings` compares the structs and functions of `llama.agc` with the llama.cpp headers (names, order, C types, parameters, that a resource is the pointer its `free:` function takes, the `sizeof` of each struct against the C compiler's, and the sizes that the helpers assume), and fails with a diff. CI runs it, and `make test-bindings` (`tests/bindings_test.agc`, run by `agentica test`) checks that it refuses each kind of wrong binding. The headers fetched are every one that `llama.h` includes.

## [0.1.0] - 2026-11-05

First release: a prototype LLM inference server, the Bond web framework in front of llama.cpp, called through the Agentica FFI.

### Added

- `POST /v1/chat/completions`, in the OpenAI shape: `messages`, `max_tokens`, `temperature`, `seed`, `stream` and `stream_options.include_usage`.
- Streaming with `"stream": true`: server-sent events, one chunk per piece of text, then `data: [DONE]`.
- `GET /health`.
- Parallel slots (`--parallel`): the requests are decoded together in one batch, and a freed slot takes the next waiting request.
- Command line options: `--model`, `--host`, `--port`, `--threads`, `--ctx`, `--parallel`, `--batch`, `--backends`, `--stats` and `--help`. A bad command line exits 2.
- `--stats on` prints, every 5 s of work, how much of the engine's time went into `llama_decode` and how much into Agentica.
- `scripts/fetch-llama.sh`: the pinned llama.cpp release, sha256-checked.
- `scripts/fetch-model.sh [REPO FILE SHA256]`: Qwen2.5-0.5B-Instruct Q4_K_M by default, or any public GGUF model on Hugging Face, sha256-checked.

### Needs

- Agentica 0.24.1 or later, Bond 0.6.1 (pinned in `agentica.toml`), llama.cpp b12012.
- Linux x86_64 (the prebuilt llama.cpp CPU build) is the only supported platform.

[Unreleased]: https://github.com/agentica-lang/agentica-llama-server/compare/0.1.0...HEAD
[0.1.0]: https://github.com/agentica-lang/agentica-llama-server/releases/tag/0.1.0

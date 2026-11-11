# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** needs Agentica 0.30.0 or later and Bond 0.10.0: the sources are formatted with `agentica fmt` of 0.30.0, which uses its syntax (implicit returns, guards, one-line defs). CI tests with Agentica 0.30.0. The request and response codecs are `ChatRequest.codec` and `ChatResponse.codec`.

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

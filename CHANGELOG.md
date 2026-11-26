# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `server_ml.agc` serves the API over the transformers of ml (Qwen3 and Qwen2.5, a Hugging Face folder or a GGUF file), one request at a time, with streaming and the usage counts; no llama.cpp library is loaded. See `docs/ml.md`.
- The routes talk to an engine through `src/llama_server/contract.agc`; `make test-api-ml` runs the API checks on the ml engine with a tiny random Qwen3.

### Changed

- **Breaking:** needs Agentica 0.38.0 (the packages of ml need it).
- `scripts/fetch.agc` downloads with `HTTP.download` and its `sha256:` check, not 32 MiB `Range` pieces: a server that ignores `Range` is no longer a failure.
- `bench/run_all.agc` takes the pid of a server from `Process.pid` and runs from any folder: the repo root is the parent of `bench/` (`--root` still names another).

## [0.2.0] - 2026-11-18

### Changed

- **Breaking:** needs Agentica 0.34.1 and Bond 0.15.1.
- llama.cpp b12359 (was b12012).
- **Breaking:** the scripts are Agentica: `agentica scripts/fetch.agc llama|headers|model|all` replaces the `.sh` files.
- **Breaking:** the tests and the benchmark are Agentica too (`tests/*_test.agc`, `bench/*.agc`): no Python needed.

### Added

- `--gpu-layers N` offloads layers to a GPU; `fetch.agc llama --variant vulkan` fetches the Vulkan build.
- `make check-bindings` compares `llama.agc` with the llama.cpp headers.
- `bench/run_all.agc` takes `--gpu-layers`, `--llama-dir` and `--root`; Vulkan results in `bench/results/`.

### Needs

- Agentica 0.34.1 or later, Bond 0.15.1 (pinned in `agentica.toml`), llama.cpp b12359.
- Linux x86_64 is the only supported platform.

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

[Unreleased]: https://github.com/agentica-lang/agentica-llama-server/compare/0.2.0...HEAD
[0.2.0]: https://github.com/agentica-lang/agentica-llama-server/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/agentica-llama-server/releases/tag/0.1.0

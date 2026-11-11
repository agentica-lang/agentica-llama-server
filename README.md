# agentica-llama-server

A prototype LLM inference server written in [Agentica](https://github.com/agentica-lang/agentica): the
[Bond](https://github.com/agentica-lang/bond) web framework in front of llama.cpp, called through the Agentica FFI
(no C code). It serves an OpenAI-shaped `POST /v1/chat/completions` and `GET /health`, with server-sent events (`"stream": true`).

## Get started

```sh
scripts/fetch-llama.sh && scripts/fetch-model.sh && agentica install
agentica server.agc --port 8080 --threads 4 --ctx 8192 --parallel 8

curl localhost:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":32,"temperature":0}'

# the same, as server-sent events
curl -N localhost:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":32,"stream":true}'
```

Needs Agentica 0.30.0 or later; Bond 0.10.0 is pinned in `agentica.toml`. Linux x86_64 is the only supported platform.

Changes per release: [CHANGELOG.md](CHANGELOG.md).

## Layout

```text
server.agc, smoke.agc     entry points, at the root (imports resolve from the importing file's folder)
src/llama_server/         the domain: engine, llama.cpp FFI bindings, numbers, command line
src/llama_server_web/     HTTP: the Bond routes (api)
```

Rule: `llama_server/` never imports `llama_server_web/`, Bond or `std/http`. The web side calls the domain, never the
reverse.

## Benchmark

On a 4-core laptop CPU (not capped) with Qwen2.5-0.5B, it is at parity with `llama-server` of the same llama.cpp
release, streaming or not (not a win): the model dominates. About 28 to 44 tok/s on both; the time to first token is
0.3 s on both at concurrency 1. At concurrency 4 it was 11 to 18 % ahead in the full sets but not in the 3-minute quick
run (`bench/run_all.py --quick`); at 8 threads and concurrency 1 it was about 9 % behind. The CPU cap is gone, so only
the ratios compare with older runs. Caveats: [docs/benchmark.md](docs/benchmark.md).

## Docs

- [docs/running.md](docs/running.md): dependencies, server options, tests.
- [docs/architecture.md](docs/architecture.md): the engine, continuous batching, sampling, the file map.
- [docs/benchmark.md](docs/benchmark.md): setup, method, results, how to rerun, where the overhead is.
- [docs/gaps.md](docs/gaps.md): gaps found in Agentica, Bond and the FFI.

## License

Apache License 2.0. See [LICENSE](LICENSE).

Moves agentica-llm to Agentica 0.20.0, on the Bond 0.4.0 it already pins (Bond needs no release for this).

- `agentica.toml`, `README.md`, `docs/running.md`, `docs/architecture.md`: Agentica 0.20.0. The benchmark docs and results keep the versions they were measured with.
- No source change was needed. With a 0.20.0 binary built from the tag: `agentica check` is ok (6 files, so no CHECK-LINE-TOO-LONG), and `python3 -m unittest tests.test_api` runs 8 tests, OK (the server starts with 4 slots on the llama.cpp b12012 libraries and the Qwen2.5-0.5B model). The repo has no `ca_file`, TLS, `HttpClientOptions` or `closed?` use, and no CI workflow or CHANGELOG to update. `agentica.lock` is unchanged by `agentica install`.

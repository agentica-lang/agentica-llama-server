# Running

## Fetch the dependencies

```sh
agentica scripts/fetch.agc all    # or: llama, headers, model [REPO FILE SHA256]
agentica install
```

Run from the repo root. `scripts/fetch.agc` is a program in Agentica (`make fetch` runs it): the downloads follow
redirects, are taken in 32 MiB pieces and are checked against their sha256 before they take their name, and each step
skips what it has. It does not import the bindings, so it runs before the libraries that the manifest names exist.

- `llama [--variant vulkan]`: llama.cpp v1.0.0 (build b12359), Linux x86-64 CPU build (or the Vulkan build, see
  [GPU](#gpu)), sha256-checked, into `native/linux/`, because Agentica only loads `[native]` files from a `native/`
  folder (see [gaps.md](gaps.md)). The libraries are there by their soname (`libllama.so.1`), and `libggml-cpu-*.so`,
  which ggml loads from the same folder, and `llama-server` for the benchmark come with them. The release is
  `scripts/llama-release`: its tag, the sha256 of its archive (and of the Vulkan one) and the sha256 of each header. The
  files that it keeps are listed in `scripts/fetch.agc` (`RELEASE_MEMBERS`); a release with other files needs that list
  changed.
- `model`: Qwen2.5-0.5B-Instruct Q4_K_M, sha256-checked, into `deps/`. For any other public GGUF model on Hugging Face,
  pass the repo, the file and its sha256, for example `agentica scripts/fetch.agc model Qwen/Qwen2.5-1.5B-Instruct-GGUF
  qwen2.5-1.5b-instruct-q4_k_m.gguf <sha256>`, then run the server with `--model
  deps/qwen2.5-1.5b-instruct-q4_k_m.gguf`. The default model is the one of `scripts/model`. `HF_ENDPOINT` replaces
  `https://huggingface.co`.
- `headers`: `llama.h` of the same tag and the headers it includes, into `deps/headers`. The release archive ships no
  headers, and the structs and signatures of `src/llama_server/llama.agc` are copied from `llama.h`. A wrong field list
  is undefined behavior, so `make check-bindings` (after `fetch.agc headers` and `llama`) compares them: the field
  names, order and C types of each bound struct, the parameters and result of each bound function, and the size of each
  struct with the `sizeof` of the C compiler (`cc`, or `agentica scripts/check_bindings.agc --skip-sizes` without one).
  The check is `scripts/check_bindings.agc`. Run it when you change the release (the new sha256s go in
  `scripts/llama-release`; the check fails on headers fetched for another tag); CI runs it.
- `agentica install`: Bond 0.15.1 (git dependency, pinned by tag in `agentica.toml` and by commit and hash in
  `agentica.lock`).

Nothing under `deps/` is committed.

## Run the server

```sh
agentica server.agc --port 8080 --threads 4 --ctx 8192 --parallel 8
```

Add `"stream": true` to get server-sent events, one `data:` chunk per piece of text and `data: [DONE]` at the end
(`-N` keeps curl from buffering):

```sh
curl -N localhost:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":32,"stream":true}'
```

`"stream_options": {"include_usage": true}` adds a last chunk with the token counts.

Options: `--model PATH --host H --port N --threads N --ctx N --parallel N --batch N --gpu-layers N --backends DIR
--stats on|off` (`--name value` or `--name=value`); `--help` lists them with their defaults. A bad command line is a
message on stderr and exit 2; a failure to load the model or to listen is `error: ...` and exit 1.

llama.cpp logs a lot to stderr at start (a log callback cannot be set, see [gaps.md](gaps.md)); send it to a file.
`--stats on` prints, every 5 s of work, how much of the engine's time went into `llama_decode` and how much into
Agentica.

## GPU

`--gpu-layers N` (default 0, the CPU) offloads N layers of the model to the GPU; a number above the layer count, such as
99, offloads all of them. It needs a build of llama.cpp with a GPU backend, and the server loads the backends from
`--backends` (`native/linux`):

```sh
agentica scripts/fetch.agc llama --variant vulkan
agentica server.agc --gpu-layers 99
```

`--variant vulkan` fetches the Vulkan build of the same release (it adds `libggml-vulkan.so`; the other libraries have
the same names, so `agentica.toml` does not change). Vulkan needs a driver on the machine, for example Mesa's RADV for
an AMD GPU or iGPU (`mesa-vulkan-drivers`). `fetch.agc llama` with no variant
puts the CPU build back. On one AMD iGPU all 25 layers of the 0.5B model were offloaded, and the prompt
was about 8 times faster than on the CPU.

With a GPU, the `--stats` `decode_ms` is not reliable: `llama_decode` returns before the GPU is done, and the wait lands
in `agentica_ms`. CI has no GPU: it runs the CPU build with `--gpu-layers 0`.

## Test

```sh
make test    # or: make test-bindings test-fetch test-cli test-api
agentica test tests/api_test.agc
```

`make check`, `make fmt-check` and `make test` run the type check, the format check and the four test files (`make
install` fetches the packages; `AGENTICA=` picks the binary). Each `make test-*` fails unless its file passes the count
of tests in the `Makefile`, so a run that tests nothing fails. CI runs them on Linux with the pinned Agentica release,
in [.github/workflows/ci.yml](../.github/workflows/ci.yml).

`tests/api_test.agc` starts the server (`Process`, a free port, the log in `tests/server.log`) with 4 slots and talks
HTTP to it: the routes, the streamed chunks (they add up to the non-streaming greedy answer, UTF-8 stays whole, the
stream ends with `[DONE]`), the 400 answers, and that clients that leave mid-stream free their slots. The server is
closed when the run ends, failed or not.

`tests/cli_test.agc` checks the flags (`--help`, bad values, a valid set) and needs the llama.cpp libraries, not the
model.


`tests/bindings_test.agc` runs `scripts/check_bindings.agc` on the committed `llama.agc` (it must pass), then on copies
with one mistake each: a removed or swapped field, a wrong field or parameter type, a missing parameter, an unknown
function, a wrong `free:`, a resource in the place of another, a wrong helper size, a struct size that differs from the
C one. Each must fail and name its struct or function. It needs the headers, the llama.cpp libraries and `cc`; `make
test-bindings` also checks the count of passed tests.

`tests/fetch_test.agc` runs `scripts/fetch.agc` against a local server in the test that redirects (to a path, a relative
path or in a loop) and serves `Range` pieces (a 34 MiB file): the file arrives with the right sha256 and no `.part`, a
second run says "already fetched", a stale file is replaced, and a wrong sha256, a loop, a 404 (not retried) and a
server that ignores `Range` exit 1 and leave no file. A release archive without the expected files keeps the libraries
that were there. It needs no network; `make test-fetch` also checks the count of passed tests.

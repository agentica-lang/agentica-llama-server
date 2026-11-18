# Running

## Fetch the dependencies

```sh
agentica scripts/fetch.agc all    # or: llama, headers, model [REPO FILE SHA256]
agentica install
```

Run from the repo root. `scripts/fetch.agc` is a program in Agentica (`make fetch` runs it): the downloads follow
redirects, are taken in 32 MiB pieces and are checked against their sha256 before they take their name, and each step
skips what it has. It does not import the bindings, so it runs before the libraries that the manifest names exist.

- `llama`: llama.cpp v1.0.0 (build b12359), Linux x86-64 CPU build, sha256-checked, into `native/linux/`, because
  Agentica only loads `[native]` files from a `native/` folder (see [gaps.md](gaps.md)). The libraries are there by their
  soname (`libllama.so.1`), and `libggml-cpu-*.so`, which ggml loads from the same folder, and `llama-server` for the
  benchmark come with them. The release is `scripts/llama-release`: its tag, the sha256 of its archive and the sha256 of each header. The files that
  it keeps are listed in `scripts/fetch.agc` (`RELEASE_MEMBERS`); a release with other files needs that list changed.
- `model`: Qwen2.5-0.5B-Instruct Q4_K_M, sha256-checked, into `deps/`. For any other public GGUF model on Hugging Face,
  pass the repo, the file and its sha256, for example
  `agentica scripts/fetch.agc model Qwen/Qwen2.5-1.5B-Instruct-GGUF qwen2.5-1.5b-instruct-q4_k_m.gguf <sha256>`, then run
  the server with `--model deps/qwen2.5-1.5b-instruct-q4_k_m.gguf`. The default model is the one of `scripts/model`. `HF_ENDPOINT` replaces `https://huggingface.co`.
- `headers`: `llama.h` of the same tag and the headers it includes, into `deps/headers`. The release archive ships no
  headers, and the structs and signatures of `src/llama_server/llama.agc` are copied from `llama.h`. A wrong field list
  is undefined behavior, so `make check-bindings` (after `fetch.agc headers` and `llama`) compares them: the field names,
  order and C types of each bound struct, the parameters and result of each bound function, and the size of each struct
  with the `sizeof` of the C compiler (`cc`, or `agentica scripts/check_bindings.agc --skip-sizes` without one). The check
  is `scripts/check_bindings.agc`. Run it when you change the release (the new sha256s go in `scripts/llama-release`; the check fails on headers fetched for another tag);
  CI runs it.
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

Options: `--model PATH --host H --port N --threads N --ctx N --parallel N --batch N --backends DIR --stats on|off`
(`--name value` or `--name=value`); `--help` lists them with their defaults. A bad command line is a message on stderr
and exit 2; a failure to load the model or to listen is `error: ...` and exit 1.

llama.cpp logs a lot to stderr at start (a log callback cannot be set, see [gaps.md](gaps.md)); send it to a file.
`--stats on` prints, every 5 s of work, how much of the engine's time went into `llama_decode` and how much into
Agentica.

## Test

```sh
AGENTICA=/path/to/agentica python3 -m unittest tests.test_api
AGENTICA=/path/to/agentica python3 -m unittest tests.test_cli
agentica test tests/bindings_test.agc
agentica test tests/fetch_test.agc
```

`make check`, `make fmt-check` and `make test` run the type check, the format check and the four test files (`make install`
fetches the packages; `AGENTICA=` picks the binary). CI runs them on Linux with the pinned Agentica release, in
[.github/workflows/ci.yml](../.github/workflows/ci.yml).

`tests.test_api` starts the server with 4 slots and checks the routes, the streamed chunks (they add up to the
non-streaming greedy answer, UTF-8 stays whole, the stream ends with `[DONE]`) and that clients that leave mid-stream
free their slots.

`tests.test_cli` checks the flags (`--help`, bad values, a valid set) and needs the llama.cpp libraries, not the model.

`tests/bindings_test.agc` runs `scripts/check_bindings.agc` on the committed `llama.agc` (it must pass), then on copies with one
mistake each: a removed or swapped field, a wrong field or parameter type, a missing parameter, an unknown function, a wrong
`free:`, a resource in the place of another, a wrong helper size, a struct size that differs from the C one. Each must fail and
name its struct or function. It needs the headers, the llama.cpp libraries and `cc`; `make test-bindings` also checks the
count of passed tests.

`tests/fetch_test.agc` runs `scripts/fetch.agc model` against a local server in the test that redirects to a path and serves `Range`
pieces (a 34 MiB file): the file arrives with the right sha256 and no `.part`, a second run says "already fetched", and a wrong
sha256 exits 1 naming both digests and leaves no file. It needs no network; `make test-fetch` also checks the count of passed tests.

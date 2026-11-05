# Running

## Fetch the dependencies

```sh
scripts/fetch-llama.sh
scripts/fetch-model.sh
scripts/fetch-headers.sh
agentica install
```

- [scripts/fetch-llama.sh](../scripts/fetch-llama.sh): llama.cpp b12012, Linux x86-64 CPU build, sha256-checked, into
  `deps/llama.cpp`. It also links the libraries into `native/linux/` because Agentica only loads `[native]` files from
  a `native/` folder (see [gaps.md](gaps.md)).
- [scripts/fetch-model.sh](../scripts/fetch-model.sh): Qwen2.5-0.5B-Instruct Q4_K_M, sha256-checked, into `deps/`. For
  any other public GGUF model on Hugging Face, pass the repo, the file and its sha256, for example
  `scripts/fetch-model.sh Qwen/Qwen2.5-1.5B-Instruct-GGUF qwen2.5-1.5b-instruct-q4_k_m.gguf <sha256>`, then run the
  server with `--model deps/qwen2.5-1.5b-instruct-q4_k_m.gguf`.
- [scripts/fetch-headers.sh](../scripts/fetch-headers.sh): `llama.h` of the same tag, only to compare the struct
  layouts in `src/llama_server/llama.agc`. The release archive ships no headers, so the struct layouts were copied from `llama.h` at
  tag `b12012`; a wrong field list is undefined behavior, so re-check them if you change the tag.
- `agentica install`: Bond 0.6.1 (git dependency, pinned by tag in `agentica.toml` and by commit and hash in
  `agentica.lock`; Bond 0.4.0 does not run on Agentica 0.23.0).

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
```

`make check`, `make fmt-check` and `make test` run the type check, the format check and both test modules (`make install`
fetches the packages; `AGENTICA=` picks the binary). CI runs them on Linux with the pinned Agentica release, in
[.github/workflows/ci.yml](../.github/workflows/ci.yml).

`tests.test_api` starts the server with 4 slots and checks the routes, the streamed chunks (they add up to the
non-streaming greedy answer, UTF-8 stays whole, the stream ends with `[DONE]`) and that clients that leave mid-stream
free their slots.

`tests.test_cli` checks the flags (`--help`, bad values, a valid set) and needs the llama.cpp libraries, not the model.

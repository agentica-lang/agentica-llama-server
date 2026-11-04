# Gaps found in Agentica, Bond and the FFI

Each is a short bullet with a repro. Rechecked with Agentica 0.23.0 and still failing: `Int` `min`/`max`, `case` as an
expression, the entry file in a subfolder, the `[native]` file path and the order of a defs-only `extern` block. The
callback and bulk write limits are as the 0.23.0 reference states them; the other repros were not rerun.

Closed since the first version:

- No flag parser: `std/option_parser` (Agentica 0.23.0) replaced the loop over `System.args()` (`src/llama_server/cli.agc`). What
  it still lacks (limits of an `Int`, the help layout, `on`/`off` values) is agentica-lang/agentica#1048.
- Bond had no streaming body (Bond 0.2.0 has `Bond.stream` and `Bond.sse`) and `Bond.json` encoded a struct twice
  (Bond 0.2.0 has `Bond.json_as` with a codec).
- No hex literals: `0x80` works since Agentica 0.19.0. `utf8_complete` (`src/llama_server/engine.agc`) still writes `128`, `192`,
  `224` and `240`.
- A channel could not say "the reader left" without a send: since Agentica 0.20.0 `closed?` is `true` as soon as the
  channel is closed. The engine does not use it yet: it sends with a timeout of 0 and treats any failed send (still the
  strings `channel: closed` and `channel: timed out`, which the reference says not to match on) as "stop this
  sequence", so it learns that the client left at the next token, and a request whose client leaves before its first
  token (the route is blocked in `recv`) still runs until that token.

- **No way to set a llama.cpp callback.** FFI callbacks exist since Agentica 0.19.0 (#851), but a callback runs only
  inside a plain `def` call, on the caller's task: one that C calls from a `compute def` or from a thread of its own
  gives zero and the call fails with `RUNTIME-NATIVE-CALLBACK`. `llama_model_load_from_file` and `llama_decode` are
  `compute def` (`src/llama_server/llama.agc`), and ggml calls from its own threads, so the log, `progress_callback` and
  `abort_callback` cannot be set: `agentica smoke.agc` prints about 200 KB of llama.cpp log lines to stderr at start.
- **A project `[native]` file must be under `native/`.** `[native.llama]` with `linux = { file = "deps/llama.cpp/libllama.so.0" }`
  fails: `PKG-MANIFEST-INVALID ... not a native file ... a native file is a path in the native/ folder of the package`.
  A prebuilt library that lives elsewhere (a fetched release) needs symlinks into `native/linux/` (what
  `scripts/fetch-llama.sh` does) or an absolute `system` path that cannot be committed. A project-relative path
  anywhere in the tree would fix it.
- **`Int` has no `min` or `max`.** `n_batch.min(512)` is `CHECK-UNKNOWN-METHOD: Int has no method "min"`.
  Agentica 0.23.0 added `n.clamp(lo, hi)` and `[a, b].min.unwrap!`, but a clamp needs a lower bound that the call
  sites do not have and the list form allocates on the engine's step path, so `src/llama_server/numbers.agc` keeps
  `smaller(a, b)` for the three files that need it.
- **An entry file in a subfolder cannot import the project's `src/` by its project path.** `tools/smoke.agc` with
  `import Llama from "src/llama_server/llama"` fails with `CHECK-IMPORT-IO: cannot resolve import`: imports resolve
  relative to the importing file's folder, so a runnable program sits at the repo root, or names the file with `../`
  as `src/llama_server_web/api.agc` does. Since Agentica 0.21.0 the diagnostic names the path it tried and the
  `../` form.
- **A defs-only `extern` block has to come after every block that has a resource or a struct**, in the same file
  (`CHECK-DECL-ORDER: structs, enums, type aliases and resources come before functions`), so the one-line `ggml`
  block had to move to the end of `src/llama_server/llama.agc` and cannot sit by the library it belongs to.
- **`case` is not an expression.** `x = case r ... ok(n) -> n ... end` is `PARSE-UNEXPECTED-TOKEN: expected an
  expression, found "case"`, so unwrapping a `Result` with a fallback takes a `case` statement that assigns in each arm
  (and `try` only works in a function that returns a `Result`).
- **No bulk write of a small-int list into native memory.** Only `put_array_of_int32/int64/float32/float64`
  exist; the `int8` `logits` array of `llama_batch` goes through `Bytes.from_list` and `put_bytes`, and the
  `seq_id` pointer-to-int cells need a `get_pointer` and a `put_int32` per token.
- **Different batch shapes give different greedy text** (not an Agentica bug; llama.cpp float order). It is listed so
  nobody builds a test on "batched equals sequential".

See also the [overhead notes](benchmark.md#where-agentica-adds-overhead-and-what-would-remove-it) for what these gaps cost in the engine.

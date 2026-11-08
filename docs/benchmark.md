# Benchmark

agentica-llama-server against `llama-server` of the same llama.cpp release (b12012), on the same model and settings,
with and without streaming. The raw JSON of every run is in [bench/results/](../bench/results/): `threads4.json`,
`threads8.json` (one JSON answer per request), `threads4-stream.json` (`stream: true`, with the time to first token) and
`quick.json` (the 3-minute run, streaming). Every rep is there, with the cores the neighbours used during it. The
`threads8-stream` set was **not rerun** for this version (see below).

Versions: Agentica 0.27.0, Bond 0.10.0, llama.cpp b12012. Full sets measured on 2026-11-08 and 2026-11-09, quick run on
2026-11-09. The previous run (Agentica 0.19.0-beta.1, Bond 0.2.0, same llama.cpp) is kept in
`bench/results/0.19.0-beta.1/`.

## The machine, and what the numbers mean

AMD Ryzen 5 3550H (4 cores, 8 threads, a laptop), 12 GB, Linux 6.12. **The CPU is not capped any more**:
`scaling_max_freq` is 2100000 on all 8 cores (governor `schedutil`), read before the run and not changed. The 0.19.0-beta.1
run was capped at 1.4 GHz, so **the absolute numbers here are about 1.5 to 2 times higher** (about 28 to 44 generated
tokens per second here, against 15 to 24 there) and cannot be compared with the old ones. Both servers ran back to back
under the same state, so **the ratios between the two servers are what matter**.

It is a **shared machine**: other agents run builds and test suites on it. The runner (`bench/run_all.py`) waits for
fewer than 1.5 busy neighbour cores before each run, measures the cores the neighbours used *during* the run (the
machine's busy cores minus what the server and the client used), and redoes a run once when that was over 1.2.
The machine was idle for this run: neighbour cores during the kept runs were 0.2 to 0.4 (highest single run 0.40), no run
was redone and none failed. Treat differences under about 10 % as noise.

## Method

Both servers get the same model (Qwen2.5-0.5B-Instruct Q4_K_M), thread count (`-t` and `-tb`; 4 and 8 below), context
(`-c 8192`), slots (`-np 8`, so 1024 tokens of KV per slot in both), batch sizes (`-b 2048 -ub 512`), greedy sampling
(`temperature` 0) and `max_tokens` 64. The `llama-server` runs with `--no-webui --no-cache-prompt -cram 0` and every
request says `cache_prompt: false`, so it cannot skip the prompt work. Each server starts under
`systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 --` (a cap far above the 0.8 GB they use, so it does
not touch the timing) and is stopped by the PID the script started.

`bench/client.py` is closed-loop: N threads send requests back to back (16 requests at concurrency 1 and 4, 64 at
concurrency 16). Eight different prompts rotate; the system prompt is explicit so both chat templates give the same
prompt (about 28 prompt tokens per request). After a warm-up, each concurrency runs 3 times per server, **alternating
the servers rep by rep**, and the tables show medians of the 3.

With `--stream` every request says `"stream": true` and `stream_options.include_usage` (both servers accept it) and the
client records the time to first token (TTFT): the time until the first event whose `delta.content` is not empty. The
role-only first chunk does not count. A stream gets a new connection per request on both servers, because
`llama-server` closes the connection after a stream although it says keep-alive. Tokens come from the usage chunk.
(`llama-server` counts the end-of-answer token in `completion_tokens`, agentica-llama-server does not; with
`max_tokens` 64 nearly every answer ends at the limit, so the tok/s are comparable.)

The default command is the **quick mode**, a whole run (both servers) in about 2 minutes (123 s measured, 4 threads,
`--stream` on, so the time to first token and the tok/s come from the same requests; 32 tokens per answer, 2 reps per
cell, 4, 8 and 16 requests at concurrency 1, 4 and 16, 4 prompts for the identity check, a short warm-up):

```sh
python3 bench/run_all.py --agentica /path/to/agentica --quick --max-load 1.5 --max-load-during 1.2
```

The full mode (25 to 30 minutes per set) is the one that has 3 reps, `max_tokens` 64, more requests and a batched
identity check; the full tables below come from it:

```sh
python3 bench/run_all.py --agentica /path/to/agentica --threads 4 --max-load 1.5 --max-load-during 1.2 --attempts 2 --patience 300
python3 bench/run_all.py ... --stream      # adds time to first token
```

## Results without streaming

Medians of 3 runs. Ratio = agentica-llama-server / llama-server.

### 4 threads (one per physical core)

| server | concurrency | req/s | generated tok/s | p50 latency s | p95 latency s |
|---|---|---|---|---|---|
| agentica-llama-server | 1 | 0.59 | 37.4 | 1.69 | 1.79 |
| llama-server | 1 | 0.58 | 36.8 | 1.72 | 1.81 |
| agentica-llama-server | 4 | 0.69 | 44.3 | 5.75 | 6.14 |
| llama-server | 4 | 0.59 | 37.5 | 6.81 | 7.11 |
| agentica-llama-server | 16 | 0.65 | 41.7 | 24.31 | 28.62 |
| llama-server | 16 | 0.63 | 40.1 | 24.66 | 28.14 |

Ratios of tok/s: 1.01, 1.18, 1.04 (0.97, 0.98, 0.99 on 0.19.0-beta.1). The concurrency 4 gap is reproducible (the three
reps are 44.7, 44.3, 43.9 against 38.0, 37.5, 37.4).

### 8 threads (`nproc`)

| server | concurrency | req/s | generated tok/s | p50 latency s | p95 latency s |
|---|---|---|---|---|---|
| agentica-llama-server | 1 | 0.44 | 27.7 | 2.32 | 2.52 |
| llama-server | 1 | 0.48 | 30.3 | 2.07 | 2.39 |
| agentica-llama-server | 4 | 0.58 | 37.0 | 6.92 | 7.26 |
| llama-server | 4 | 0.51 | 32.6 | 7.87 | 8.14 |
| agentica-llama-server | 16 | 0.56 | 35.9 | 28.92 | 30.26 |
| llama-server | 16 | 0.57 | 36.3 | 28.20 | 31.24 |

Ratios of tok/s: 0.91, 1.13, 0.99 (1.01, 1.15, 1.00 on 0.19.0-beta.1). The concurrency 1 cell is the only one where
agentica-llama-server is behind: its reps are 28.9, 24.8, 27.7 against 30.7, 30.3, 29.8, so one slow rep makes most of
the gap and I would not call it a loss. The concurrency 4 gap is there again (36.4, 37.0, 37.3 against 32.6, 32.5,
33.2), now with both thread counts. I do not know why, and I would not call it a win without a look at `llama-server`'s
scheduling.

No request failed in any run. (The latency at concurrency 16 is mostly queueing: 16 clients for 8 slots.)

## Results with streaming (`stream: true` on both servers)

Medians of 3 runs. TTFT is the time to the first content token; total latency is until `data: [DONE]`.

### 4 threads

| server | concurrency | generated tok/s | TTFT p50 s | TTFT p95 s | total p50 s | total p95 s |
|---|---|---|---|---|---|---|
| agentica-llama-server | 1 | 35.5 | 0.33 | 0.42 | 1.78 | 1.91 |
| llama-server | 1 | 34.5 | 0.34 | 0.45 | 1.82 | 1.98 |
| agentica-llama-server | 4 | 43.5 | 1.45 | 1.63 | 6.01 | 6.21 |
| llama-server | 4 | 39.3 | 1.36 | 1.64 | 6.53 | 7.07 |
| agentica-llama-server | 16 | 40.6 | 13.88 | 19.43 | 24.36 | 29.22 |
| llama-server | 16 | 40.8 | 14.15 | 16.20 | 25.32 | 27.37 |

Ratios of tok/s: 1.03, 1.11, 0.99. Ratios of TTFT p50: 0.96, 1.07, 0.98 (a ratio over 1 is slower). On 0.19.0-beta.1 the
tok/s ratios were 0.98, 1.10, 1.21 and the TTFT ratios 1.02, 1.05, 0.85, but those concurrency 16 rows were noisy; this
time the machine was quiet and concurrency 16 is the same on both. The concurrency 4 gap in tok/s is there again (one
agentica-llama-server rep is 38.3 against 43.5 and 44.3), while its TTFT is a little higher (1.45 against 1.36 s), so
read it as "the same, within noise".

### 8 threads

Not rerun for 0.27.0. The full sets took 25 to 30 minutes each, and a benchmark run now has to take at most
3 minutes, so the 8-thread streaming set was stopped before it finished and its partial output was dropped. The
0.19.0-beta.1 result is in `bench/results/0.19.0-beta.1/threads8-stream.json` (capped CPU: ratios of tok/s 0.99, 1.20,
0.99, TTFT at concurrency 1 equal at 0.67 s). The 8-thread plain set above is the 0.27.0 result for 8 threads.

### Quick run (3 minutes, 4 threads, streaming)

`--quick`, 2 reps per cell (so the "median" is the mean of 2), 32 tokens per answer, 4, 8 and 16 requests: the cells
carry less data than the full sets. 123 s wall time for both servers.

| server | concurrency | generated tok/s | TTFT p50 s | TTFT p95 s | total p50 s | total p95 s |
|---|---|---|---|---|---|---|
| agentica-llama-server | 1 | 32.5 | 0.29 | 0.31 | 0.98 | 1.02 |
| llama-server | 1 | 30.9 | 0.30 | 0.35 | 1.04 | 1.06 |
| agentica-llama-server | 4 | 38.2 | 1.08 | 1.27 | 3.36 | 3.38 |
| llama-server | 4 | 39.3 | 1.15 | 1.18 | 3.25 | 3.30 |
| agentica-llama-server | 16 | 38.3 | 4.50 | 9.08 | 10.04 | 13.37 |
| llama-server | 16 | 39.1 | 4.49 | 8.82 | 9.81 | 13.08 |

Ratios of tok/s: 1.05, 0.97, 0.98. Ratios of TTFT p50: 0.98, 0.94, 1.00. Here the concurrency 4 gap of the full sets is
not there (36.8 and 39.6 against 39.2 and 39.4), so it is not as solid as it looked; the quick run says "parity". The
time to first token at concurrency 16 is lower than in the full sets only because the clients send 16 requests, not 64
(less queueing).

No request failed in any run.

### Memory (RSS, from the 4-thread runs)

| server | idle after load | peak (VmHWM), plain | peak, streaming | end of run, plain |
|---|---|---|---|---|
| agentica-llama-server | 768 MB | 834 MB | 786 MB | 799 MB |
| llama-server | 660 MB | 693 MB | 695 MB | 693 MB |

### The serving layer alone (`GET /health`, 3000 requests, both servers pinned to CPUs 0 to 3 with `taskset`)

**Not rerun**: this is the 0.19.0-beta.1 result (Bond 0.2.0, capped CPU), kept in
[bench/results/0.19.0-beta.1/health.json](../bench/results/0.19.0-beta.1/health.json). Medians of 3 runs. Measured by
hand, not by `run_all.py`: both servers started with `taskset -c 0-3` (4 threads, `-c 8192`, 8 slots), then `python3
bench/client.py --url URL --concurrency N --requests 3000 --health` for each server and concurrency, three times in turn.

| server | concurrency | req/s | p50 ms | p95 ms |
|---|---|---|---|---|
| agentica-llama-server (Bond 0.2.0 on `std/http`) | 1 | 1734 | 0.52 | 0.64 |
| llama-server | 1 | 2454 | 0.34 | 0.45 |
| agentica-llama-server | 16 | 2888 | 3.35 | 16.02 |
| llama-server | 16 | 2733 | 2.97 | 18.43 |

(One Python client process produces most of that ceiling, and the CPUs were capped.)

### Correctness checks

- Greedy answers of the two servers are identical for all 8 prompts at concurrency 1 (64 tokens each) in the three full
  sets, and for the 4 prompts (32 tokens) of the quick run.
- The streamed text equals the non-streaming greedy text (`tests/test_api.py`, with multi-byte emoji that split
  across tokens).
- Decoded side by side (concurrency 8), answers drift from the one-at-a-time ones late in the text in both servers
  (agentica-llama-server 0 to 1 of 8 identical, llama-server 0 to 2 of 8): the batch shape changes the float reduction
  order of the quantized kernels. It is not cross-sequence contamination, which would diverge at once.

## An honest reading

- **Parity, not a win.** Without streaming, agentica-llama-server is within 5 % of `llama-server` in 4 of 6 cells, ahead
  by 13 to 18 % at concurrency 4 (both thread counts) and 9 % behind at 8 threads, concurrency 1 (one slow rep). With
  streaming the same, and the quick run, which has less data, shows parity in every cell. The concurrency 4 gap shows
  in 3 of 3 full sets and in none of the quick run, so I do not trust it.
- **Streaming is free here.** At concurrency 1 the tok/s and the total latency with `stream: true` are within about 5 %
  of the plain runs on both servers. The time to first token at concurrency 1 is 0.3 s on both (one prefill of about 28
  tokens plus the first decode step, at full CPU speed; it was 0.6 to 0.7 s at the 1.4 GHz cap). It is the same on the
  two servers, so Agentica's layers (the route, the channel, the pump, Bond's SSE, `std/http`) add nothing visible to it.
- **TTFT grows with the number of requests in flight, not with the server.** At concurrency 4 it is about 1.4 s; at
  concurrency 16 it is 14 s in the full sets because 8 requests wait for a slot (the closed-loop test has more clients
  than slots).
- **The model dominates.** 0.5B Q4 on 4 cores generates about 28 to 44 tok/s here whatever sits in front of it, and
  concurrency barely raises it: CPU decode is compute-bound, so batching gains little. 8 threads are slower than 4 on
  both servers (hyper-threads share the 4 cores). The same would not hold on a GPU, where the serving layer's share of
  the step matters far more.
- **Agentica's share of the engine step is small** (measured with `--stats on` on 0.18.0 at full speed, not rerun
  here): 30 to 85 ms of Agentica work per 5 s window against 5.0 to 6.1 s inside `llama_decode`, about 1 to 1.5 %,
  around 3 to 4 ms per step. The streaming path adds a channel send per token to the step.
- **The HTTP layer is not the bottleneck either**: `/health` was about 30 % slower per request at concurrency 1 (0.52
  against 0.34 ms p50, 0.19.0-beta.1, not rerun) and on par at concurrency 16, when inference gives 0.6 requests per
  second.
- **Memory:** about 110 MB more at idle and about 140 MB more at peak than `llama-server` (the Agentica VM, the Bond app,
  and the batch/scratch buffers); on 0.19.0-beta.1 it was 20 and 95 MB. Streaming adds nothing visible. The idle number
  is higher in the plain set (768 MB) than in the streaming one (701 MB), so it moves by about 70 MB between starts; I
  did not look into why.
- Not measured: long prompts (prefill), sampling with temperature (the C sampler is the same code in both, but the
  sampler chain here is only `temp` then `dist`, not `llama-server`'s default `top-k`/`top-p`/`min-p`), a client that
  leaves mid-stream under load, and any GPU build.

## Older runs

`bench/results/0.19.0-beta.1/` holds the previous run (Agentica 0.19.0-beta.1, Bond 0.2.0, CPU capped at 1.4 GHz, all
four sets and `health.json`). `bench/results/0.18.0/` holds the JSON of the first version (Agentica 0.18.0, Bond at a
commit, no streaming) on the uncapped CPU; its conclusion was the same (parity). `bench/results/first-pass/` is a thrown-away 4-thread run of this
version: the runner then checked the neighbours only before a run, and one that started during it spoiled it (the same
cell ranged from 15 to 34 tok/s), so the runner now measures them during the run.

## Where Agentica adds overhead, and what would remove it

- **Per-token FFI writes into the batch.** `fill` writes the token, position and `n_seq_id` arrays with bulk
  `put_array_of_int32`, but the per-token `seq_id` cell still costs a `get_pointer` and a `put_int32` per token, and a
  prefill of N tokens builds `List`s of N items (a boxed `Int` each, plus `BatchItem` structs) before the copy. Compact
  `Int`/`Float` lists (#396) and a bulk way to write one int32 into many pointers would cut it.
- **Logits stay in C on purpose.** Sampling is done by llama.cpp's sampler chain (`llama_sampler_sample`); walking
  151k floats per token in Agentica would be orders of magnitude slower, and `Native.get_array_of_float32` would
  build a 151k-item `List[Float]` per row (this is where #396 matters most for any sampler written in Agentica).
- **Streaming costs a little per token, and it does not show.** Each token is a channel send from the engine (inside its
  step, with timeout 0, not timed separately), then a `JSON.encode`, a `Bond.sse_event` and a channel send to Bond in
  the pump task. Tokens per second match the non-streaming runs.
- **Sampling runs on a scheduler thread.** `llama_sampler_sample` is a plain `def`; with 16 sequences it blocks that
  scheduler for the sum of the calls. It is short (the stats show about 3 ms per step), but a `compute def` for the
  whole "sample every row" loop would be free of it. A C callback that samples inside `llama_decode` is not an option
  today: a callback cannot run in a `compute def` or from a C thread (see [gaps.md](gaps.md)).
- **llama.cpp's log goes to stderr unchecked**, because a `llama_log_set` callback cannot run there (see [gaps.md](gaps.md)).
- **One engine task, one decode at a time.** That is how `llama.cpp` works on one context, so it is no loss, but
  there is no second context to overlap prefill and decode.

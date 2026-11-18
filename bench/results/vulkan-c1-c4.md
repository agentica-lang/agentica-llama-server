# Vulkan: agentica-llama-server and llama-server on the GPU

Measured on 2026-11-18: AMD Radeon iGPU (RADV RAVEN), Qwen2.5-0.5B-Instruct Q4_K_M, llama.cpp b12359 (the Vulkan build, `fetch.agc llama --variant vulkan`), 4 threads, `--ctx 8192`, 8 slots, batch 2048, `max_tokens` 32, all layers offloaded (`--gpu-layers 99` and `-ngl 99`), concurrency 1 and 4, 1 to 2 reps (medians), the servers alternating rep by rep. A short rerun of the command with the current `bench/run_all.agc` loaded `offloaded 25/25 layers to GPU`; the offload line was not captured in the runs below.

The raw runs are in [vulkan-c1-c4.json](vulkan-c1-c4.json) (not streaming, 2 reps) and [vulkan-c1-c4-stream.json](vulkan-c1-c4-stream.json) (streaming, 1 rep). They were taken with the Python version of the runner, before it moved to Agentica; the keys are the same, `gpu_layers` was not recorded.

| conc | mode | agentica tok/s | llama.cpp tok/s | ratio |
|---|---|---|---|---|
| 1 | non-streaming | 36.8 | 31.3 | 1.18 |
| 4 | non-streaming | 56.1 | 49.8 | 1.13 |
| 1 | streaming | 36.3 | 32.3 | 1.12 |
| 4 | streaming | 72.9 | 73.8 | 0.99 |

- Time to first token at concurrency 1 (streaming): 0.10 s against 0.11 s.
- RSS: agentica 267 MB idle and 346 MB peak, llama.cpp 144 and 186 (non-streaming set); 158 and 220 against 144 and 161 (streaming set).
- Greedy answers identical between the servers on 8 of 8 prompts, in both sets.

**Caveats:** one machine, shared and noisy (a load average of about 4, neighbours used 1 to 7 cores during the runs), 1 to 2 reps, and a 32-token answer. Differences under about 10 % are noise: read this as parity on a GPU, not as a win.

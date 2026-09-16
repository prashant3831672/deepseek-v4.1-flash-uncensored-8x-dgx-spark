# Fairness probes: what other sessions get during a long prefill

Two scripts that together measure the one thing the standard benches do not: how a short,
interactive request behaves while another request is cold-prefilling a very long prompt on
the same engine. On a coding-agent cluster this is the common case, because every resumed
session with a 400K to 600K history is exactly such a prefill.

| Script | What it does |
|---|---|
| `bigprefill.py` | one cold prompt of `TARGET_TOK` tokens (unique filler, never cached) with a needle in the middle; prints TTFT, prefill rate and whether the needle came back |
| `probe_during.py` | every `GAP` seconds, a short count-to-100 request; prints its decode rate, tokens per step (acceptance), engine step p50 and max, and the engine's running/waiting/KV state before each probe |

```bash
export SPARK_URL=http://<head>:8888 SPARK_MODEL=dsv41-flash-uncensored
TARGET_TOK=200000 python3 bigprefill.py &          # terminal 1 (or background)
N=8 GAP=8 START_DELAY=12 python3 probe_during.py   # terminal 2
```

Start the probes about 10 s after the big prompt so the first probe lands inside the prefill.
`probe_during.py` stops on its own when the engine goes idle.

## Why this matters: the starvation signature

vLLM's chunked prefill gives every engine step one prompt chunk (`--max-num-batched-tokens`,
8192 in the boot-10 recipe). At long context a chunk step takes seconds, and the co-scheduled
decode requests advance one token per step, so they crawl at about 1 tok/s for the whole
prefill. New requests wait on the token budget with reason `capacity` even with most of the
KV pool free.

From the metrics side it looks like a hang: vLLM's logger only adds a request's prompt tokens
when its first output token appears, so a cold 400K prefill logs `prompt throughput: 0.0` and
`generation throughput: ~1 tok/s` for minutes, with every GPU busy at idle power. The tell
that it is progressing is `vllm:kv_cache_usage_perc` creeping upward at the prefill rate.

## The lever and what we measured (8x GB10, TP8, 1M context, DSpark k=5)

`--long-prefill-token-threshold` caps how many tokens of a long prompt join each step, so
decodes get more steps per second at a prefill-throughput cost.

| | untreated (chunk 8192) | `--long-prefill-token-threshold 2048` |
|---|---|---|
| probe decode during a cold 214K prefill | 0.1 to 1 tok/s | 2.9 to 4.3 tok/s |
| probe step time during the prefill | 4 to 10 s | 1.2 to 2.1 s |
| the prefill itself | about 1,400 tok/s | 1,295 tok/s |
| 200K needle TTFT | 150 s | 165 s (with probes competing) |
| single stream after the prefill | 55 ms/step, 104 tok/s | unchanged |

1024 or 512 buys the decodes roughly 2x more at a larger prefill cost; 2048 is what we serve.
Related and independent of the flag: at TP4 Tony measured that a 16K chunk costs about 36%
of the KV pool (activation reserve), and a 2K chunk on a four-Spark 1M recipe roughly doubled
it, so chunk size is also a memory lever.

## Reading the probe output

- `tok/step` is DSpark acceptance for the probe (5.85 on counting when the engine is unloaded);
  it should not change during a prefill. If it does, something else is wrong.
- `step p50` is the engine step time the probe sees. During a prefill it is the prompt-chunk
  time; after it, the decode step time (55 to 62 ms on this cluster).
- `kv=` rising across probes at 800 to 1,400 tok/s worth of blocks is the prefill progressing.
  Flat KV, running requests, and 0% GPU utilization is the actual wedge signature.

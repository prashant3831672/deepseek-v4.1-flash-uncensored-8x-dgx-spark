# DeepSeek Harness (dsh) against a local vLLM cluster

The client-side kit for pointing the DeepSeek Harness coding agent at this cluster (or any
OpenAI-compatible vLLM endpoint serving DeepSeek-V4.1-Flash at long context) from a Mac.
Everything here was found the hard way over two weeks of daily use; each piece fixes a
specific failure that shows up only with a local, long-context, slow-prefill backend.

| File | Installed at | What it fixes |
|---|---|---|
| `install.sh` | runs once, idempotent | prerequisites, config, shim, a pinned dsh source build |
| `settings.yaml` | `~/.dsh/settings.yaml` | the provider entry that makes dsh talk to vLLM correctly |
| `dsh-spark` | `~/.local/bin/dsh-spark` | launcher: cluster preflight, rebuild-if-stale, web UI |
| `undici-longtimeout.mjs` | `~/.local/lib/undici-longtimeout.mjs` | lifts Node's transport-level 300 s timeout |

## Install

```bash
bash client/install.sh --spark-host <head node address the laptop can reach>
# add --model <id> if the served model id is not dsv41-flash-uncensored
# add --no-clone if you already have a built deepseek-harness checkout (set DSH_REPO)
cd <project> && dsh-spark
```

The laptop must reach the head node's port 8888 directly: same LAN, or a private overlay
network (WireGuard, Tailscale, similar). Do not port-forward 8888; vLLM has no auth.

## The four things that matter, and why

**1. The provider must be hand-declared with `compat` overrides.** pi-ai (dsh's provider
layer) cannot recognise a private URL and addresses it as OpenAI itself: developer role,
`max_completion_tokens`, a bare `reasoning_effort`. vLLM's DeepSeek-V4.1 template rejects
that. `thinkingFormat: deepseek`, `supportsDeveloperRole: false`, `maxTokensField: max_tokens`
fix it. A hand-declared route also needs an `apiKeyEnv` even when the server has no auth,
so the launcher exports a dummy `SPARK_API_KEY`.

**2. Two timeout layers, both default to 5 minutes, and prefill is silent.** A cold turn on
a long history holds the HTTP stream open with no bytes until the whole prompt is prefilled.
At 1,200 to 2,100 prompt tokens per second that is minutes for a 400K history.

- Application level: `timeoutMs` and `streamIdleTimeoutMs` in the provider entry. The 300,000 ms
  default killed every large prompt, then dsh retried five times, and the concurrent retries
  are what collapsed cluster throughput. Set both to 3,600,000.
- Transport level: Node's `fetch` uses undici, whose `headersTimeout` and `bodyTimeout` also
  default to 300,000 ms and which the provider settings never reach. The symptom is a bare
  `terminated` (code `TRANSPORT`) on the client while the server completes the request and logs
  HTTP 200. `undici-longtimeout.mjs` installs a global dispatcher with 60-minute timeouts;
  the launcher loads it through `NODE_OPTIONS=--import`. Verified: a request survives 310 s of
  silence with the shim and dies at 300 s without it.

Rule of thumb: the largest cold prompt a client can survive is prefill rate times the
transport timeout. At 1,300 tok/s and 300 s that is about 390K tokens, which is why the
failures cluster around the 400K mark on untreated clients.

**3. Reasoning effort "off" must be a valueless key.** V4.1 thinks only when a
`reasoning_effort` is sent, so "off" means "omit the parameter". In YAML that is `"off":`
with nothing after the colon. An empty string silently invalidates the whole provider and it
disappears from the model picker with no error.

**4. A source checkout needs the native addon built.** dsh 0.1.5 and later use a flock
addon that a source checkout does not ship prebuilt; without `pnpm build:native-system`
every session resume fails with "Cannot find module .../system.node". The launcher builds it
if it is missing. The `npx @deepseek-ai/dsh` route avoids this but re-resolves the registry
on every launch and stalls for minutes; a built checkout starts in a second.

## What to expect at 1M context

| Situation | What happens |
|---|---|
| Fresh session, short prompts | first token in 0.3 to 0.7 s, 80 to 100 tok/s |
| Resuming a long session that is still in the prefix cache | first token in seconds |
| Cold turn on a 400K to 600K history | 3 to 8 minutes of silence, then normal speed; the launcher and shim keep the request alive |
| Several agents at once during one cold prefill | the others slow to a few tokens per second until it finishes (see `bench/fairness/`) |
| Images in history | vLLM's `--limit-mm-per-prompt` caps images per request; dsh resends old ones, so raise the server limit or trim images from history |

## Health checks from the laptop

```bash
curl -s http://<head>:8888/v1/models | python3 -m json.tool | grep -E '"id"|max_model_len'
curl -s http://<head>:8888/metrics | grep -E '^vllm:num_requests_(running|waiting)\{'
```

A cold prefill in progress looks like a hang from the metrics side (prompt throughput 0.0,
generation about 1 tok/s, one request running). The tell that it is progressing is
`vllm:kv_cache_usage_perc` creeping upward at the prefill rate. Do not restart on that alone.

## Gotchas

| Symptom | Cause and fix |
|---|---|
| provider missing from the picker | the `"off":` key has a value; make it valueless |
| `No API key for provider: spark` | hand-declared route without `apiKeyEnv`; the launcher exports the dummy |
| `terminated` with code `TRANSPORT` at exactly 300 s | the undici shim is not loaded; check `NODE_OPTIONS` |
| turn retried five times, cluster crawls | `streamIdleTimeoutMs` still at the default |
| `400 At most N image(s)` | the server's image limit; raise `--limit-mm-per-prompt` or trim history |
| every resume fails with a missing `system.node` | run `pnpm build:native-system` in the checkout |
| `npx -y @deepseek-ai/dsh` stalls for minutes | it re-resolves the registry every launch; use the built checkout |

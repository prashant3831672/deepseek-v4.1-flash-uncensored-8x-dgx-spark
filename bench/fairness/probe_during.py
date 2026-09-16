#!/usr/bin/env python3
"""While a big prefill runs elsewhere: repeatedly send a short request and report its decode rate and
step time, plus the engine's running/waiting/KV state before each probe. Stops after N probes or when
the engine goes idle.

  SPARK_URL=http://<head>:8888 SPARK_MODEL=dsv41-flash-uncensored N=6 GAP=8 START_DELAY=12 python3 probe_during.py

Reads: tok/s (decode rate of the probe), tok/step (DSpark acceptance), step p50 and max (how long each
engine step takes while the other request's prefill chunks share the step).
"""
import json, os, re, time, urllib.request

BASE = os.environ.get("SPARK_URL", "http://HEAD_IP_PLACEHOLDER:8888").rstrip("/")
MODEL = os.environ.get("SPARK_MODEL", "dsv41-flash-uncensored")
N = int(os.environ.get("N", "6")); GAP = float(os.environ.get("GAP", "8")); START_DELAY = float(os.environ.get("START_DELAY", "12"))
COUNT = "Count from 1 to 100, separated by spaces. Output only the numbers."


def metrics():
    try:
        txt = urllib.request.urlopen(f"{BASE}/metrics", timeout=5).read().decode()
    except Exception as e:
        return f"metrics err {e}"
    g = lambda k: (re.search(rf"^vllm:{k}\{{[^}}]*\}} ([0-9.e+]+)", txt, re.M) or [None, "?"])[1]
    kv = float(g("kv_cache_usage_perc") or 0) * 100
    return f"run={g('num_requests_running')} wait={g('num_requests_waiting')} kv={kv:.1f}%"


def probe(tag):
    body = {"model": MODEL, "messages": [{"role": "user", "content": f"[{tag}] {COUNT}"}], "max_tokens": 200,
            "temperature": 0, "stream": True, "stream_options": {"include_usage": True, "continuous_usage_stats": True}}
    req = urllib.request.Request(f"{BASE}/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time(); pts = []
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            u = (json.loads(line[6:]).get("usage") or {}); ct = u.get("completion_tokens")
            if ct is not None and (not pts or ct > pts[-1][1]):
                pts.append((time.time() - t0, ct))
    if len(pts) < 3:
        return f"{tag}: too few chunks"
    steps = [(pts[i][0] - pts[i - 1][0]) * 1000 for i in range(2, len(pts))]
    steps_s = sorted(steps); med = steps_s[len(steps_s) // 2]
    toks = pts[-1][1] - pts[1][1]; tps = toks / (pts[-1][0] - pts[1][0])
    return (f"{tag}: {pts[-1][1]} tok, TTFT {pts[0][0]:.2f}s, {tps:5.1f} tok/s, {toks / len(steps):.2f} tok/step, "
            f"step p50 {med:6.1f} ms, max {max(steps):6.0f} ms, wall {pts[-1][0]:.1f}s")


time.sleep(START_DELAY)
for i in range(N):
    m = metrics(); t = time.strftime("%H:%M:%S", time.gmtime())
    print(f"{t} before probe {i + 1}: {m}", flush=True)
    print("   " + probe(f"probe{i + 1}-{int(time.time())}"), flush=True)
    if "run=0.0" in m and i > 0:
        print("engine idle, stopping", flush=True); break
    time.sleep(GAP)

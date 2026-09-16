#!/usr/bin/env python3
"""Send one cold prompt of about TARGET_TOK tokens (non-streaming, tiny answer) and report TTFT and prefill rate.

Unique pseudo-prose filler so the prefix cache never hits, plus a needle in the middle so the
answer proves the prompt was read. Run this in one terminal and probe_during.py in another to
measure what co-scheduled requests get while a long prefill runs.

  SPARK_URL=http://<head>:8888 SPARK_MODEL=dsv41-flash-uncensored TARGET_TOK=200000 python3 bigprefill.py
"""
import json, os, random, time, urllib.request

BASE = os.environ.get("SPARK_URL", "http://HEAD_IP_PLACEHOLDER:8888").rstrip("/")
MODEL = os.environ.get("SPARK_MODEL", "dsv41-flash-uncensored")
TARGET_TOK = int(os.environ.get("TARGET_TOK", "200000"))

rnd = random.Random(time.time_ns())
words = ["ledger", "harbor", "quartz", "meadow", "signal", "copper", "falcon", "orbit",
         "timber", "velvet", "cinder", "prism", "tundra", "marble", "saddle", "lantern"]
n_words = int(TARGET_TOK / 1.3)  # about 1.3 tokens per word for this filler
body = " ".join(rnd.choice(words) + (str(rnd.randint(0, 999)) if rnd.random() < 0.2 else "") for _ in range(n_words))
needle = f"The secret code word is NIGHTJAR-{rnd.randint(1000, 9999)}."
pos = len(body) // 2
prompt = body[:pos] + " " + needle + " " + body[pos:] + "\n\nWhat is the secret code word? Answer with just the code word."

req = {"model": MODEL, "messages": [{"role": "user", "content": prompt}], "max_tokens": 16, "temperature": 0}
t0 = time.time()
r = urllib.request.Request(f"{BASE}/v1/chat/completions", json.dumps(req).encode(), {"Content-Type": "application/json"})
with urllib.request.urlopen(r, timeout=3600) as resp:
    d = json.load(resp)
t1 = time.time()
u = d.get("usage", {})
pt = u.get("prompt_tokens", 0)
print(f"bigprefill: prompt_tokens={pt} total={t1 - t0:.1f}s prefill_rate={pt / (t1 - t0):.0f} tok/s "
      f"answer={d['choices'][0]['message']['content']!r} expected={needle.split()[-1]}", flush=True)

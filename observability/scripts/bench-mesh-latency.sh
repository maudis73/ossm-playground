#!/usr/bin/env bash
# Benchmark mesh latency: correlate X-Request-Id across proxy access logs and Tempo spans.
# Requires: oc, curl, python3. Phases 7–8 must be applied.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bench-mesh-latency.sh [options]

Send N requests to productpage with unique UUID X-Request-Id headers, then report
Tempo trace durations (Kiali-comparable) and per-hop proxy access-log durations.

Options:
  -n COUNT       Requests to measure (default: 20)
  --parallel N   Concurrent curl workers (default: 1)
  --warmup N     Extra warmup requests excluded from stats (default: 1)
  --sleep SEC    Seconds to wait after traffic for Tempo ingest (default: 20)
  --pause SEC    Pause between sequential requests (default: 0.25; ignored if --parallel > 1)
  --since DUR    Ignored (logs use --since-time from batch start)
  --tempo-max N  Max Tempo lookups (default: all measured requests; 0 to skip)
  -o FILE        Also write markdown report to FILE
  -h, --help     Show this help

Environment:
  APP_NS, TEMPO_NS, TEMPO_SVC

Example (from repository root):
  ./observability/scripts/bench-mesh-latency.sh -n 100 --parallel 100 --sleep 25 -o observability/docs/mesh-latency-report.md
EOF
}

COUNT=20
PARALLEL=1
WARMUP=1
SLEEP_AFTER=20
PAUSE=0.25
LOG_SINCE="5m"
TEMPO_MAX=""
OUTPUT=""
APP_NS="${APP_NS:-ossm-playground-apps}"
TEMPO_NS="${TEMPO_NS:-tempostack}"
TEMPO_SVC="${TEMPO_SVC:-tempo-simplest-query-frontend.tempostack.svc.cluster.local:3200}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) COUNT="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --sleep) SLEEP_AFTER="$2"; shift 2 ;;
    --pause) PAUSE="$2"; shift 2 ;;
    --since) LOG_SINCE="$2"; shift 2 ;;
    --tempo-max) TEMPO_MAX="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for cmd in oc curl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

export APP_NS TEMPO_NS TEMPO_SVC COUNT PARALLEL WARMUP SLEEP_AFTER PAUSE LOG_SINCE TEMPO_MAX OUTPUT

exec python3 - <<'PYTHON'
import json
import os
import re
import statistics
import subprocess
import sys
import time
import uuid
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

APP_NS = os.environ["APP_NS"]
TEMPO_NS = os.environ["TEMPO_NS"]
TEMPO_SVC = os.environ["TEMPO_SVC"]
COUNT = int(os.environ["COUNT"])
PARALLEL = int(os.environ["PARALLEL"])
WARMUP = int(os.environ["WARMUP"])
SLEEP_AFTER = float(os.environ["SLEEP_AFTER"])
PAUSE = float(os.environ["PAUSE"])
LOG_SINCE = os.environ["LOG_SINCE"]
TEMPO_MAX = os.environ["TEMPO_MAX"]
OUTPUT = os.environ["OUTPUT"]
if TEMPO_MAX == "":
    TEMPO_MAX = COUNT
else:
    TEMPO_MAX = int(TEMPO_MAX)

APPS = ["productpage", "details", "reviews", "ratings"]
BATCH_ID = int(time.time())
BATCH_START = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(BATCH_ID))

SPAN_TO_PROXY = {
    "productpage | productpage": "productpage inbound GET /productpage",
    "productpage | details": "productpage outbound GET /details/0",
    "details | details": "details inbound GET /details/0",
    "productpage | reviews": "productpage outbound GET /reviews/0",
    "reviews | reviews": "reviews inbound GET /reviews/0",
    "reviews | ratings": "reviews outbound GET /ratings/0",
    "ratings | ratings": "ratings inbound GET /ratings/0",
}


def run(cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def oc(*args, check=True):
    return run(["oc", *args], check=check)


def tempo_get(path, query_params=None):
    pod = f"bench-{uuid.uuid4().hex[:8]}"
    cmd = [
        "oc", "run", pod, "--rm", "-i", "--restart=Never", "-n", TEMPO_NS,
        "--image=curlimages/curl:8.5.0", "--command", "--",
        "curl", "-sfG", f"http://{TEMPO_SVC}{path}",
    ]
    for key, value in (query_params or {}).items():
        cmd.extend(["--data-urlencode", f"{key}={value}"])
    r = run(cmd, check=False)
    if r.returncode != 0:
        return None
    body = r.stdout.split(f'pod "{pod}"')[0].strip()
    return body or None


def parse_hop(line):
    parts = line.split('"')
    path = parts[1]
    nums = parts[4].split()
    dur, upstream = int(nums[2]), int(nums[3])
    direction = "inbound" if "inbound|" in line else "outbound"
    path_short = re.sub(r" HTTP/1\.1$", "", path)
    return path_short, direction, dur, upstream


def short_span_name(svc, name):
    svc_short = svc.split(".")[0]
    short = name
    if ".svc." in name:
        short = name.split(".")[0]
    short = short.replace(".ossm-playground-apps", "").replace("/*", "")
    return f"{svc_short} | {short}"


def stats(xs):
    if not xs:
        return None
    xs = sorted(xs)
    n = len(xs)

    def pct(p):
        if n == 1:
            return xs[0]
        k = (n - 1) * p / 100
        f = int(k)
        c = min(f + 1, n - 1)
        return xs[f] + (xs[c] - xs[f]) * (k - f)

    return {
        "n": n,
        "avg": statistics.mean(xs),
        "med": statistics.median(xs),
        "p95": pct(95),
        "min": xs[0],
        "max": xs[-1],
    }


def row_stats(label, s):
    if not s:
        return f"| {label} | - | - | - | - | - | - | 0 |"
    return (
        f"| {label} | {s['avg']:.1f} | {s['med']:.1f} | {s['p95']:.1f} | "
        f"{s['min']:.1f} | {s['max']:.1f} | {s['n']} |"
    )


def parse_request_id(line):
    parts = line.split('"')
    if len(parts) < 10:
        return None
    return parts[9]


def latest_inbound_request_id(seen=None):
    seen = seen or set()
    log = oc(
        "logs", "-n", APP_NS, "-l", "app=productpage", "-c", "istio-proxy",
        f"--since-time={BATCH_START}",
    ).stdout
    for line in reversed(log.splitlines()):
        if '"GET /productpage HTTP/1.1"' not in line or "inbound|" not in line:
            continue
        rid = parse_request_id(line)
        if rid and rid not in seen:
            return rid
    return None


def wait_for_request_id(seen, attempts=12, delay=0.5):
    for _ in range(attempts):
        rid = latest_inbound_request_id(seen)
        if rid:
            return rid
        time.sleep(delay)
    return None


def curl_one(url, marker=None):
    headers = []
    if marker:
        headers = ["-H", f"X-Request-Id: {marker}"]
    r = run(["curl", "-sS", "-o", "/dev/null", *headers, url], check=False)
    if r.returncode != 0:
        return None, r.stderr.strip()
    return None, None


def curl_and_capture(url, seen, marker=None):
    err_ref, err = curl_one(url, marker)
    if err:
        return err_ref, err
    rid = wait_for_request_id(seen)
    if not rid:
        return marker or "?", "no request id in access log"
    seen.add(rid)
    return rid, None


def merge_logs(existing, new):
    seen = set(existing.splitlines()) if existing else set()
    lines = existing.splitlines() if existing else []
    for line in new.splitlines():
        if line not in seen:
            seen.add(line)
            lines.append(line)
    return "\n".join(lines)


def tail_proxy_logs():
    logs = {}
    for app in APPS:
        logs[app] = oc(
            "logs", "-n", APP_NS, "-l", f"app={app}", "-c", "istio-proxy",
            f"--since-time={BATCH_START}", "--tail=500",
        ).stdout
    return logs


def fetch_proxy_logs():
    return tail_proxy_logs()


def fetch_tempo_batch(refs):
    results = {}
    for ref in refs:
        body = None
        for _ in range(3):
            body = tempo_get("/api/search", {"tags": f"guid:x-request-id={ref}", "limit": "1"})
            if body:
                try:
                    if json.loads(body).get("traces"):
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(1.5)
        if not body:
            continue
        try:
            search = json.loads(body)
        except json.JSONDecodeError:
            continue
        traces = search.get("traces", [])
        if not traces:
            continue
        tid = traces[0]["traceID"]
        duration_ms = traces[0].get("durationMs", 0)
        raw = tempo_get(f"/api/traces/{tid}")
        spans = {}
        root_span_ms = None
        if raw:
            try:
                trace = json.loads(raw)
                for batch in trace.get("batches", []):
                    svc = next(
                        (a["value"]["stringValue"] for a in batch["resource"]["attributes"] if a["key"] == "service.name"),
                        "?",
                    )
                    for ss in batch.get("scopeSpans", []):
                        for span in ss.get("spans", []):
                            key = short_span_name(svc, span.get("name", "?"))
                            dur = (int(span["endTimeUnixNano"]) - int(span["startTimeUnixNano"])) / 1e6
                            spans[key] = dur
                            if key == "productpage | productpage":
                                root_span_ms = max(root_span_ms or 0, dur)
            except json.JSONDecodeError:
                pass
        results[ref] = {"duration_ms": duration_ms, "root_span_ms": root_span_ms, "spans": spans}
        time.sleep(0.5)
    return results


route = oc("get", "route", "productpage", "-n", APP_NS, "-o", "jsonpath={.spec.host}").stdout.strip()
url = f"https://{route}/productpage"
total_requests = WARMUP + COUNT

print(f"Route: {url}")
print(f"Batch: {BATCH_ID}")
print(f"Sending {total_requests} requests ({WARMUP} warmup + {COUNT} measured, parallel={PARALLEL})...")
print("Correlating via Istio request id from productpage inbound access logs (Tempo tag guid:x-request-id).")

curl_all = [False] * total_requests
measured_refs = []
seen_ids = set()
pod_logs = {app: "" for app in APPS}

def snapshot_logs():
    global pod_logs
    chunk = tail_proxy_logs()
    for app in APPS:
        pod_logs[app] = merge_logs(pod_logs[app], chunk[app])

# Warmup sequential
for i in range(WARMUP):
    _, err = curl_and_capture(url, seen_ids)
    if err:
        print(f"  warmup warning: {err}", file=sys.stderr)
    snapshot_logs()
    if PAUSE > 0:
        time.sleep(PAUSE)

# Measured traffic
measured_indices = list(range(WARMUP, total_requests))
if PARALLEL > 1:
    markers = {i: f"bench-{BATCH_ID}-{i}" for i in measured_indices}
    workers = min(PARALLEL, len(measured_indices))

    def run_marked(i):
        return i, curl_one(url, markers[i])

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run_marked, i): i for i in measured_indices}
        for fut in as_completed(futures):
            i, (_, err) = fut.result()
            curl_all[i] = err is None
            if err:
                print(f"  warning {markers[i]}: {err}", file=sys.stderr)
    measured_refs = list(markers.values())
    snapshot_logs()
else:
    for i in measured_indices:
        rid, err = curl_and_capture(url, seen_ids)
        curl_all[i] = err is None
        if err:
            print(f"  warning: {err}", file=sys.stderr)
        elif rid:
            measured_refs.append(rid)
        snapshot_logs()
        if PAUSE > 0:
            time.sleep(PAUSE)

curl_ok = sum(1 for i in measured_indices if curl_all[i])

snapshot_logs()
print(f"Collected {sum(len(v.splitlines()) for v in pod_logs.values())} proxy log lines.")

print(f"Waiting {SLEEP_AFTER:.0f}s for Tempo ingest...")
time.sleep(SLEEP_AFTER)

tempo_refs = measured_refs
if TEMPO_MAX == 0:
    tempo_refs = []
elif len(measured_refs) > TEMPO_MAX:
    step = len(measured_refs) / TEMPO_MAX
    tempo_refs = [measured_refs[int(i * step)] for i in range(TEMPO_MAX)]

print(f"Looking up {len(tempo_refs)} traces in Tempo...")
tempo_by_ref = fetch_tempo_batch(tempo_refs)
tempo_matched = len(tempo_by_ref)
trace_durations = [v["duration_ms"] for v in tempo_by_ref.values()]
root_span_durations = [v["root_span_ms"] for v in tempo_by_ref.values() if v["root_span_ms"] is not None]
span_durs = defaultdict(list)
for data in tempo_by_ref.values():
    for key, dur in data["spans"].items():
        span_durs[key].append(dur)

hop_durs = defaultdict(list)
edge_by_ref = {}
access_matched = 0

for ref in measured_refs:
    found_edge = False
    for app, logs in pod_logs.items():
        for line in logs.splitlines():
            if ref not in line:
                continue
            path, direction, dur, _ = parse_hop(line)
            key = f"{app} {direction} {path}"
            hop_durs[key].append(dur)
            if app == "productpage" and direction == "inbound" and path == "GET /productpage":
                edge_by_ref[ref] = dur
                found_edge = True
    if found_edge:
        access_matched += 1

edge_durs = list(edge_by_ref.values())
paired_tempo = []
paired_access = []
paired_delta = []

for ref in measured_refs:
    if ref in edge_by_ref and ref in tempo_by_ref:
        t = tempo_by_ref[ref]["duration_ms"]
        a = edge_by_ref[ref]
        paired_tempo.append(t)
        paired_access.append(a)
        paired_delta.append(a - t)

edge_s = stats(edge_durs)
trace_s = stats(trace_durations)
root_s = stats(root_span_durations)
pair_tempo_s = stats(paired_tempo)
pair_access_s = stats(paired_access)
pair_delta_s = stats(paired_delta)

lines = []
lines.append(f"# Mesh latency benchmark — batch `{BATCH_ID}`\n")
lines.append(f"- **Route:** `{url}`")
lines.append(f"- **Measured requests:** {COUNT} ({PARALLEL} parallel workers)")
lines.append(f"- **Warmup:** {WARMUP}")
lines.append(f"- **HTTP OK:** {curl_ok}/{COUNT}")
lines.append(f"- **Captured request ids:** {len(measured_refs)}/{COUNT}")
lines.append(f"- **Access-log match:** {access_matched}/{COUNT}")
lines.append(f"- **Tempo match:** {tempo_matched}/{len(tempo_refs)}")
lines.append(f"- **Paired (Tempo + access log):** {len(paired_tempo)}\n")

lines.append("## Kiali — trace duration (Tempo `durationMs`, ms)\n")
lines.append("Same value as the **Y-axis / duration** on the Kiali Traces scatter plot.\n")
lines.append("| Metric | avg | median | p95 | min | max | n |")
lines.append("|--------|-----|--------|-----|-----|-----|---|")
lines.append(row_stats("Tempo trace durationMs", trace_s))
lines.append(row_stats("Tempo productpage root span", root_s))

lines.append("\n## Access logs — mesh edge (productpage inbound proxy, ms)\n")
lines.append("Envoy `duration` on the **inbound** productpage hop — per-hop proxy wall time.\n")
lines.append("| Metric | avg | median | p95 | min | max | n |")
lines.append("|--------|-----|--------|-----|-----|-----|---|")
lines.append(row_stats("productpage inbound GET /productpage", edge_s))

if pair_tempo_s and pair_access_s:
    lines.append("\n## Same request — Tempo vs access log (ms)\n")
    lines.append("Per-request pairs where both Tempo trace and access log were found.\n")
    lines.append("| Metric | avg | median | p95 | min | max | n |")
    lines.append("|--------|-----|--------|-----|-----|-----|---|")
    lines.append(row_stats("Tempo trace durationMs", pair_tempo_s))
    lines.append(row_stats("Access log productpage inbound", pair_access_s))
    lines.append(row_stats("Δ access log − Tempo", pair_delta_s))

lines.append("\n## Access logs — per-hop proxy duration (ms)\n")
lines.append("| Hop | avg | median | p95 | min | max | n |")
lines.append("|-----|-----|--------|-----|-----|-----|---|")
for key in sorted(hop_durs.keys()):
    lines.append(row_stats(key, stats(hop_durs[key])))

if span_durs:
    lines.append("\n## Kiali — per-span duration (Tempo, ms)\n")
    lines.append("| Span | avg | median | p95 | min | max | n |")
    lines.append("|------|-----|--------|-----|-----|-----|---|")
    for key in sorted(span_durs.keys()):
        lines.append(row_stats(key, stats(span_durs[key])))

    lines.append("\n## Span vs access log — same hop (ms)\n")
    lines.append("| Hop | span avg | span med | span p95 | proxy avg | proxy med | proxy p95 | Δ avg | n |")
    lines.append("|-----|----------|----------|----------|-----------|-----------|-----------|-------|---|")
    for span_key, proxy_key in SPAN_TO_PROXY.items():
        ss, ps = stats(span_durs.get(span_key, [])), stats(hop_durs.get(proxy_key, []))
        if not ss and not ps:
            continue
        if ss and ps:
            delta = ps["avg"] - ss["avg"]
            n = min(ss["n"], ps["n"])
            lines.append(
                f"| {span_key} | {ss['avg']:.1f} | {ss['med']:.1f} | {ss['p95']:.1f} | "
                f"{ps['avg']:.1f} | {ps['med']:.1f} | {ps['p95']:.1f} | {delta:+.1f} | {n} |"
            )
        else:
            lines.append(f"| {span_key} | - | - | - | - | - | - | - | - |")
elif TEMPO_MAX > 0:
    lines.append("\n## Tempo\n")
    lines.append("No traces matched. Increase `--sleep` or check tracing pipeline.\n")

if hop_durs:
    naive = sum(statistics.mean(hop_durs[k]) for k in hop_durs)
    lines.append(f"\n**Naive sum of per-hop access-log averages:** {naive:.1f} ms (overcounts — parallel branches)")
    if trace_s:
        lines.append(f"\n**Kiali typical trace duration (median):** {trace_s['med']:.1f} ms")
    if edge_s:
        lines.append(f"**Access-log mesh edge (median):** {edge_s['med']:.1f} ms")

report = "\n".join(lines)

print()
print("=" * 72)
print(report.replace("# Mesh latency benchmark", "MESH LATENCY BENCHMARK").replace("## ", "\n## "))
print()
print("Notes:")
print("- Kiali Traces scatter plot shows Tempo trace durationMs (~median above).")
print("- Access logs show per-hop Envoy proxy duration (often higher under load).")
print("- Request ID is the quoted UUID after user-agent in proxy logs.")
print("- Tempo/Kiali correlation uses that Istio request id (guid:x-request-id tag), not a client header you send.")
print("- Critical path ≈ max(details branch, reviews branch), not sum of hops.")

if OUTPUT:
    os.makedirs(os.path.dirname(OUTPUT) or ".", exist_ok=True)
    with open(OUTPUT, "w") as f:
        f.write(report)
        f.write("\n")
    print(f"\nWrote report: {OUTPUT}")
PYTHON

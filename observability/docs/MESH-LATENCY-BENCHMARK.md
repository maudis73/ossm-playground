# Mesh latency benchmark

How we measure Bookinfo latency **inside** the service mesh using proxy access logs (Phase 8) and Tempo trace durations as shown in **Kiali** (Phase 7).

**Script:** [`observability/scripts/bench-mesh-latency.sh`](../scripts/bench-mesh-latency.sh) (run from repository root)

---

## What we built

| Phase | Capability | Used here |
|-------|------------|-----------|
| 7 | OTLP tracing → Tempo | **Kiali-comparable** trace / span durations |
| 8 | Envoy access logs on `istio-proxy` | **Per-hop** proxy timings |

The benchmark script:

1. Sends **N** sequential `GET /productpage` requests (optional `--parallel` for burst tests).
2. Captures the **Istio request id** from each response’s productpage inbound access log line.
3. Accumulates proxy logs during the run (the API only returns a short tail on bulk fetch).
4. Looks up Tempo traces with `tags=guid:x-request-id=<that id>`.
5. Reports **avg, median, p95, min, max, n** for Kiali metrics and access-log hops side by side.

**We do not report curl wall time** — it includes route/TLS/client latency outside the mesh and is not comparable to Kiali or proxy logs.

### Correlation rules

- The request id in access logs is the **quoted UUID** after the user-agent field.
- **Do not send `X-Request-Id` and expect it to match** — Istio generates its own id; the script reads it from the inbound log after each request.
- **Tempo trace ID ≠ request id**; Kiali/Tempo search uses span tag `guid:x-request-id=<request id from log>`.
- **Kiali trace duration** = Tempo `durationMs` on the trace (scatter-plot Y axis).
- **Access-log mesh edge** = `productpage inbound GET /productpage` Envoy `duration`.
- Under sequential light load these match closely; under burst load access logs can read higher per hop.
- **`details` and `reviews` are parallel** — never sum hop averages for total time.

---

## How to run

```bash
chmod +x observability/scripts/bench-mesh-latency.sh

# Recommended: sequential, full Tempo + access-log pairing
./observability/scripts/bench-mesh-latency.sh -n 20 --sleep 25 -o observability/docs/mesh-latency-results-raw.md

# Burst load (access logs only; Tempo tag search is best-effort under parallel markers)
./observability/scripts/bench-mesh-latency.sh -n 100 --parallel 100 --warmup 5 --sleep 30 --tempo-max 0 \
  -o docs/mesh-latency-results-raw.md
```

| Flag | Purpose |
|------|---------|
| `-n` | Measured requests |
| `--parallel` | Concurrent curl workers (default 1) |
| `--warmup` | Requests excluded from stats |
| `--sleep` | Wait after traffic before Tempo lookup (logs captured immediately) |
| `--tempo-max` | Cap Tempo lookups (default all measured; `0` to skip) |
| `-o` | Write markdown tables to file |

---

## Run: 20 sequential requests (2026-06-19)

**Cluster:** `ocp4.masales.cloud` · **Namespace:** `ossm-playground-apps` · **Batch:** `1781846364`

```bash
./observability/scripts/bench-mesh-latency.sh -n 20 --sleep 25 -o observability/docs/mesh-latency-results-raw.md
```

| Parameter | Value |
|-----------|-------|
| Measured requests | 20 |
| HTTP OK | 20 / 20 |
| Access-log match | **20 / 20** |
| Tempo match | **20 / 20** |
| Paired (same request) | **20 / 20** |

### Kiali — trace duration (Tempo `durationMs`, ms)

| Metric | avg | median | p95 | min | max | n |
|--------|-----|--------|-----|-----|-----|---|
| Tempo trace durationMs | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |
| Tempo productpage root span | 18.1 | 17.8 | 21.2 | 15.4 | 26.0 | 20 |

These are the values you see on the **Kiali Traces** scatter plot for `productpage`.

### Access logs — mesh edge (ms)

| Metric | avg | median | p95 | min | max | n |
|--------|-----|--------|-----|-----|-----|---|
| productpage inbound GET /productpage | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |

### Same request — Tempo vs access log (ms)

| Metric | avg | median | p95 | n |
|--------|-----|--------|-----|---|
| Tempo trace durationMs | 17.6 | 17.0 | 20.3 | 20 |
| Access log productpage inbound | 17.6 | 17.0 | 20.3 | 20 |
| Δ access log − Tempo | 0.0 | 0.0 | 0.0 | 20 |

At light sequential load, **Kiali and access-log edge durations agree** (median **17 ms**).

### Access logs — per-hop proxy duration (ms)

| Hop | avg | median | p95 | n |
|-----|-----|--------|-----|---|
| productpage inbound GET /productpage | 17.6 | 17.0 | 20.3 | 20 |
| productpage outbound GET /reviews/0 | 6.5 | 6.0 | 8.2 | 20 |
| reviews inbound GET /reviews/0 | 6.0 | 5.5 | 8.2 | 20 |
| productpage outbound GET /details/0 | 1.2 | 1.0 | 2.0 | 20 |
| details inbound GET /details/0 | 1.0 | 1.0 | 2.0 | 20 |
| reviews outbound GET /ratings/0 | 1.1 | 1.0 | 1.1 | 20 |
| ratings inbound GET /ratings/0 | 0.2 | 0.0 | 1.1 | 20 |

**Critical path:** reviews branch (~6 ms outbound + ~6 ms inbound) dominates over details (~1 ms). Naive sum of hop averages ≈ **34 ms** — misleading; meaningful E2E = **productpage inbound median 17 ms**.

---

## Historical: 100 parallel requests (2026-06-18)

Under **100 simultaneous requests**, access-log **mesh edge median was 253.5 ms** (avg 256 ms, p95 443 ms) — queueing on a small Bookinfo deployment. That run predates the Kiali-focused report format; see git history for curl wall-time tables. The lesson stands: **parallel load inflates per-hop access-log durations** while Kiali trace medians stay much lower if you inspect individual traces during quiet periods.

---

## Workshop talking points

1. **Kiali shows Tempo `durationMs`** — use the sequential benchmark table to relate scatter-plot points to numbers.
2. **Access logs give per-hop Envoy `duration`** — same request id on every hop (quoted UUID in the log line).
3. **productpage inbound** is the single-number mesh E2E from access logs.
4. **median for typical, p95 for tail** — both tables include the same stats.
5. **Do not sum hops** — Bookinfo fan-out is parallel.
6. **Span vs access-log table** shows small per-hop deltas at light load; gaps widen under burst contention.

---

## Files

| File | Purpose |
|------|---------|
| `observability/scripts/bench-mesh-latency.sh` | Runnable benchmark |
| `docs/mesh-latency-results-raw.md` | Machine-generated tables from latest `-o` run |
| `docs/MESH-LATENCY-BENCHMARK.md` | This document |

Raw output is regenerated on each `-o` run; this document captures methodology and interpreted results.

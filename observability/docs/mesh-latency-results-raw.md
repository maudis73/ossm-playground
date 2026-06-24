# Mesh latency benchmark — batch `1781846364`

- **Route:** `https://productpage-ossm-playground-apps.apps.ocp4.masales.cloud/productpage`
- **Measured requests:** 20 (1 parallel workers)
- **Warmup:** 1
- **HTTP OK:** 20/20
- **Captured request ids:** 20/20
- **Access-log match:** 20/20
- **Tempo match:** 20/20
- **Paired (Tempo + access log):** 20

## Kiali — trace duration (Tempo `durationMs`, ms)

Same value as the **Y-axis / duration** on the Kiali Traces scatter plot.

| Metric | avg | median | p95 | min | max | n |
|--------|-----|--------|-----|-----|-----|---|
| Tempo trace durationMs | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |
| Tempo productpage root span | 18.1 | 17.8 | 21.2 | 15.4 | 26.0 | 20 |

## Access logs — mesh edge (productpage inbound proxy, ms)

Envoy `duration` on the **inbound** productpage hop — per-hop proxy wall time.

| Metric | avg | median | p95 | min | max | n |
|--------|-----|--------|-----|-----|-----|---|
| productpage inbound GET /productpage | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |

## Same request — Tempo vs access log (ms)

Per-request pairs where both Tempo trace and access log were found.

| Metric | avg | median | p95 | min | max | n |
|--------|-----|--------|-----|-----|-----|---|
| Tempo trace durationMs | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |
| Access log productpage inbound | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |
| Δ access log − Tempo | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 20 |

## Access logs — per-hop proxy duration (ms)

| Hop | avg | median | p95 | min | max | n |
|-----|-----|--------|-----|-----|-----|---|
| details inbound GET /details/0 | 1.0 | 1.0 | 2.0 | 0.0 | 2.0 | 20 |
| productpage inbound GET /productpage | 17.6 | 17.0 | 20.3 | 15.0 | 25.0 | 20 |
| productpage outbound GET /details/0 | 1.2 | 1.0 | 2.0 | 1.0 | 2.0 | 20 |
| productpage outbound GET /reviews/0 | 6.5 | 6.0 | 8.2 | 5.0 | 12.0 | 20 |
| ratings inbound GET /ratings/0 | 0.2 | 0.0 | 1.1 | 0.0 | 3.0 | 20 |
| reviews inbound GET /reviews/0 | 6.0 | 5.5 | 8.2 | 5.0 | 11.0 | 20 |
| reviews outbound GET /ratings/0 | 1.1 | 1.0 | 1.1 | 1.0 | 3.0 | 20 |

## Kiali — per-span duration (Tempo, ms)

| Span | avg | median | p95 | min | max | n |
|------|-----|--------|-----|-----|-----|---|
| details | details | 1.3 | 1.2 | 2.2 | 1.0 | 2.4 | 20 |
| productpage | details | 1.9 | 1.8 | 2.9 | 1.6 | 3.0 | 20 |
| productpage | productpage | 18.1 | 17.8 | 21.2 | 15.4 | 26.0 | 20 |
| productpage | reviews | 7.1 | 6.6 | 8.9 | 6.0 | 12.7 | 20 |
| ratings | ratings | 1.0 | 0.8 | 1.5 | 0.7 | 3.1 | 20 |
| reviews | ratings | 1.5 | 1.4 | 2.1 | 1.2 | 3.8 | 20 |
| reviews | reviews | 6.5 | 6.0 | 8.3 | 5.5 | 11.5 | 20 |

## Span vs access log — same hop (ms)

| Hop | span avg | span med | span p95 | proxy avg | proxy med | proxy p95 | Δ avg | n |
|-----|----------|----------|----------|-----------|-----------|-----------|-------|---|
| productpage | productpage | 18.1 | 17.8 | 21.2 | 17.6 | 17.0 | 20.3 | -0.5 | 20 |
| productpage | details | 1.9 | 1.8 | 2.9 | 1.2 | 1.0 | 2.0 | -0.7 | 20 |
| details | details | 1.3 | 1.2 | 2.2 | 1.0 | 1.0 | 2.0 | -0.3 | 20 |
| productpage | reviews | 7.1 | 6.6 | 8.9 | 6.5 | 6.0 | 8.2 | -0.6 | 20 |
| reviews | reviews | 6.5 | 6.0 | 8.3 | 6.0 | 5.5 | 8.2 | -0.5 | 20 |
| reviews | ratings | 1.5 | 1.4 | 2.1 | 1.1 | 1.0 | 1.1 | -0.4 | 20 |
| ratings | ratings | 1.0 | 0.8 | 1.5 | 0.2 | 0.0 | 1.1 | -0.7 | 20 |

**Naive sum of per-hop access-log averages:** 33.6 ms (overcounts — parallel branches)

**Kiali typical trace duration (median):** 17.0 ms
**Access-log mesh edge (median):** 17.0 ms

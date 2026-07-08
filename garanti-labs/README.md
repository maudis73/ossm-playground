# Garanti BBVA — hands-on runbook (single guide)

Linear runbook for Garanti follow-up questions **Q3–Q12** on **OpenShift Service Mesh 3 sidecar mode**.

Run all `oc apply` commands from the **repository root** (`ossm-playground/`).

After each lab, fill in [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md).

---

## Table of contents

1. [What this runbook is for](#what-this-runbook-is-for)
2. [Before you start](#before-you-start)
3. [How to run PromQL](#how-to-run-promql)
4. [Lab 0 — Foundation](#lab-0--foundation)
5. [Lab 1 — gRPC load balancing & DestinationRule (Q3)](#lab-1--grpc-load-balancing--destinationrule-q3)
6. [Lab 2 — Key mesh metrics (Q4)](#lab-2--key-mesh-metrics-q4)
7. [Lab 3 — Sidecar latency (Q6)](#lab-3--sidecar-latency-q6)
8. [Lab 4 — Mesh ↔ non-mesh & webhooks (Q8)](#lab-4--mesh--non-mesh--webhooks-q8)
9. [Lab 5 — Retry policy (Q9)](#lab-5--retry-policy-q9)
10. [Lab 6 — Gateway protocols (Q10)](#lab-6--gateway-protocols-q10)
11. [Lab 7 — Envoy logging & recovery (Q11)](#lab-7--envoy-logging--recovery-q11)
12. [Lab 8 — VS/DR lifecycle (Q12)](#lab-8--vsdr-lifecycle-q12)
13. [Suggested schedule](#suggested-schedule)
14. [Cleanup (all labs)](#cleanup-all-labs)
15. [PromQL quick reference](#promql-quick-reference)

---

## What this runbook is for

Garanti runs **~3,200 services** on OSSM sidecar mode. This guide turns their written questions into **small, safe demos** in a pilot namespace so you can say *“we tried this; here’s what we saw”* — not benchmark the full fleet.

| Act | Labs | Customer message |
|-----|------|-------------------|
| **See the mesh** | Lab 0 | Observability on OpenShift: metrics, traces, access logs — **pilot namespaces** |
| **Measure it** | Labs 2–3 | No magic “mesh overhead” metric — PromQL for trends; logs/traces for proxy ms |
| **Operate it** | Labs 1, 4–8 | gRPC migration, egress, retries, gateway, logging, config churn |

**Not in scope:** ambient mesh, Argo canary at 3k services, universal latency benchmarks, fleet-wide Kiali.

---

## Before you start

### Shared cluster rules

| Rule | Detail |
|------|--------|
| **Namespaces** | `ossm-playground-apps` (meshed), `ossm-playground-plain` (non-mesh), `ossm-playground-perf` (optional) |
| **Do not re-patch** | `cluster-monitoring-config`, `Istio/default` if already configured — **verify first** |
| **Load** | Short bursts only: `-qps 10 -duration 30s` |
| **Routes** | Unique hostname prefix if you add ingress |
| **Logging** | Access logs / debug on **one namespace or one pod** — never mesh-wide debug |

### Prerequisite checks

```bash
oc get ns | grep ossm-playground
oc get csv -A | egrep 'servicemesh|kiali|tempo|opentelemetry'
oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' ; echo
oc get pods -n openshift-user-workload-monitoring
```

If `enableUserWorkload` is not `true`, apply once (coordinate on shared clusters):

```bash
oc apply -f observability/manifests/00-user-workload-monitoring.yaml
```

---

## How to run PromQL

PromQL queries **Prometheus/Thanos** (read-only). They do not change the cluster.

### Where

1. **OpenShift Console → Observe → Metrics**
2. Paste the query → **Run**
3. Use **Table** view for labels (pod names, workloads); **Graph** for trends

### Before querying

| Step | Why |
|------|-----|
| Generate traffic (browse app, or client already running) | No traffic → empty results |
| Wait **1–2 minutes** | PodMonitor scrapes every ~30s |
| Add `reporter="destination"` when counting requests | Without it, source + destination sidecars **double-count** (5 rps shows as ~10) |

### How to read common patterns

| Piece | Meaning |
|-------|---------|
| `istio_requests_total` | Counter: total requests since pod started |
| `rate(...[5m])` | Requests **per second**, averaged over last 5 minutes |
| `sum(...) by (label)` | Group results (per pod, per workload, …) |
| `histogram_quantile(0.99, ...)` | **p99 latency** from histogram buckets |
| `response_code=~"5.."` | HTTP 5xx errors |

**What you do with results:** screenshot or note the number → compare before/after a lab change → one bullet in [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md).

---

## Lab 0 — Foundation

**Customer topics:** partial Q4 (metrics pipeline), Q6 methods (access logs + tracing setup), observability at scale (~3,200 services).

**Goal:** Deploy the sidecar observability workshop. Unlocks all other labs (Bookinfo + metrics + traces + access logs).

Manifests live under `observability/manifests/` (not `garanti-labs/`).

### Deploy phases 1–8

```bash
# Phase 1 — apps (Bookinfo + route)
oc apply -f observability/manifests/01-apps-namespace.yaml
oc apply -f observability/manifests/02-bookinfo.yaml
oc apply -f observability/manifests/03-route.yaml
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s

# Phase 2 — Istio CNI
oc apply -f observability/manifests/04-istio-cni-namespace.yaml
oc apply -f observability/manifests/05-istio-cni-default.yaml

# Phase 3 — control plane
oc apply -f observability/manifests/06-control-plane-namespace.yaml
oc apply -f observability/manifests/07-istio-default.yaml
oc wait istio/default -n istio-system --for=condition=Ready --timeout=600s

# Phase 4 — mesh enrollment (sidecar injection)
oc apply -f observability/manifests/08-apps-mesh-enroll.yaml
oc rollout restart deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
oc get pods -n ossm-playground-apps   # expect 2/2 per pod

# Phase 5 — metrics + Kiali
oc apply -f observability/manifests/10-podmonitor.yaml
oc apply -f observability/manifests/11-telemetry-metrics.yaml
oc apply -f observability/manifests/12-kiali.yaml

# Phase 6 — tracing backend (MinIO + Tempo + OTel collector)
oc apply -f observability/manifests/minio/
oc apply -f observability/manifests/13-tempostack-namespace.yaml
oc apply -f observability/manifests/14-minio-traces-secret.yaml
oc apply -f observability/manifests/15-tempostack.yaml
oc apply -f observability/manifests/16-otel-collector.yaml

# Phase 7 — enable tracing on mesh + Kiali
oc apply -f observability/manifests/17-istio-tracing.yaml
oc apply -f observability/manifests/18-telemetry-tracing.yaml
oc apply -f observability/manifests/19-kiali-tracing.yaml

# Phase 8 — access logs
oc apply -f observability/manifests/20-telemetry-accesslogs.yaml
```

### What each phase accomplishes

| Phase | Deploys | Accomplishes |
|-------|---------|--------------|
| 0 | User-workload monitoring CM | OpenShift can scrape metrics from app namespaces |
| 1 | Namespace, Bookinfo, Route | Demo app + public URL |
| 2 | Istio CNI | OSSM networking without privileged init on every pod |
| 3 | `istio-system`, Istio CR | Control plane (istiod, ingress gateway) |
| 4 | Namespace labels + rollout | **Sidecar injection** — pods become `2/2` |
| 5 | PodMonitor, Telemetry metrics, Kiali | Proxy stats → Prometheus → **Kiali graph** |
| 6 | Tempo stack + collector | Backend to **store traces** |
| 7 | Tracing Telemetry + Kiali update | Spans in **Kiali Traces** tab |
| 8 | Access-log Telemetry | Per-request timing on `istio-proxy` stdout |

### Verify

```bash
echo "https://$(oc get route productpage -n ossm-playground-apps -o jsonpath='{.spec.host}')/productpage"
oc get pods -n ossm-playground-apps -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready
echo "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

- **Kiali graph:** `productpage → details`, etc.
- **Phase 8 required for Lab 1:** access logs on every meshed `istio-proxy` (including `grpc-client`) — one line per request with upstream IP.

### What to tell Garanti

- Global **`Telemetry`** in `istio-system` + **`PodMonitor` per namespace** for metrics.
- Tracing + access logs in **pilot namespaces** only at ~3,200 services.

---

## Lab 1 — gRPC & DestinationRule (Q3, Q5, Q10)

**Prereq:** Lab 0 phases 5 + 8 (metrics + access logs).

### Read this first (30 seconds)

```text
[fortio client] ──► [sidecar on client pod] ──► [echo pod A / B / C]
                         ▲
                   DestinationRule settings apply HERE
```

**Two checks — use the right one:**

| Command | Answers |
|---------|---------|
| `./garanti-labs/lab1-grpc/watch-pods.sh` | **Live:** each request → which echo pod (best for demos) |
| `./garanti-labs/lab1-grpc/check.sh pods` | **Snapshot:** summary over last 60s — GOOD or BAD |
| `./garanti-labs/lab1-grpc/check.sh connections` | **Does the sidecar reuse TCP** or open a new one each request? |

These are **different questions**. `maxRequestsPerConnection` changes **recycle rate**; `tcp.maxConnections` **caps** how many wires per pod.

| Phase | DR knob | `./check.sh connections` (≈150 RPCs / 30s) |
|-------|---------|-----------------------------------------------|
| No DR | defaults | ~**6** ports — reuse |
| Step 2 | `maxRequestsPerConnection: 1` | ~**150** — new TCP every RPC |
| Step 2b | `tcp.maxConnections: 1` + `-c 1` client | ~**3** — one wire per pod |
| Step 2b | same DR + `-c 2` client (default) | ~**6** — 2× channels × 3 pods |

```bash
chmod +x garanti-labs/lab1-grpc/check.sh garanti-labs/lab1-grpc/watch-pods.sh garanti-labs/lab1-grpc/test-gateway-grpc.sh
```

**Live pod spread** (run in a second terminal while traffic flows):

```bash
./garanti-labs/lab1-grpc/watch-pods.sh
```

Each line is one RPC. The address after `->` is the echo pod (`10.128.0.85:8079` etc.). You should see **different** `.85` / `.86` / `.87` values rotate. Ctrl+C to stop.

> Do **not** use `grep fortio` to find the pod — our client pod is named `grpc-client-*` (fortio is only the container name).

Optional slides: [`lab1-grpc/slides/grpc-mesh-connections.html`](lab1-grpc/slides/grpc-mesh-connections.html) · PowerPoint: [`lab1-grpc/slides/grpc-mesh-connections.pptx`](lab1-grpc/slides/grpc-mesh-connections.pptx) (regenerate: `python3 lab1-grpc/slides/generate-ppt.py`)

---

### Step 1 — Deploy server + client (no DR)

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/01-grpc-echo.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client.yaml
oc rollout status deployment/grpc-echo deployment/grpc-client -n ossm-playground-apps --timeout=180s
sleep 60
```

**Client:** Fortio `-c 2` (two long-lived channels to the sidecar), `-qps 5` (five RPCs/s total).

```bash
./garanti-labs/lab1-grpc/check.sh pods
./garanti-labs/lab1-grpc/check.sh connections
```

**Want:** pods **GOOD** (3) · connections **~6 out of ~150** (REUSING TCP)

Optional: `./garanti-labs/lab1-grpc/watch-pods.sh` in a second terminal.

---

### Step 2 — `maxRequestsPerConnection: 1` (churn, not LB change)

**Before:** `./check.sh connections` → **~6 / ~150** REUSING TCP  
**Apply:** `oc apply -f garanti-labs/lab1-grpc/manifests/05-destinationrule-max-req-per-conn.yaml` → `sleep 35`  
**After:** `./check.sh connections` → **~150 / ~150** NEW TCP EVERY REQUEST  
**Also:** `./check.sh pods` → still **GOOD** (pods unchanged)

---

### Step 2b — `tcp.maxConnections: 1` (cap upstream TCP per pod)

Restores reuse (`maxRequestsPerConnection: 0`). Limits **concurrent** TCP **to each echo pod**.

**Why you may still see ~6 with the default client (`-c 2`):**

```text
Fortio -c 2  →  2 channels app → sidecar
maxConnections: 1 per pod per pool  →  up to 2 × 3 pods = 6 TCPs
```

That is the **same ~6 as Step 1** — the cap is working; it is **not** “3 for the whole service.”

**To see ~3**, switch to one client channel first:

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client-single-conn.yaml
oc rollout status deployment/grpc-client -n ossm-playground-apps --timeout=120s
oc apply -f garanti-labs/lab1-grpc/manifests/10-destinationrule-max-connections.yaml
sleep 35
./garanti-labs/lab1-grpc/check.sh connections
./garanti-labs/lab1-grpc/check.sh pods
```

**Want:** connections **~3 / ~150** · pods **GOOD**

| Client | `maxConnections: 1` | `./check.sh connections` |
|--------|---------------------|---------------------------|
| `-c 2` (default) | per pod per channel | **~6** / ~150 |
| `-c 1` | per pod | **~3** / ~150 |
| either | `maxReq=1` (Step 2) | **~150** / ~150 |

**Restore before idleTimeout:**

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/03-destinationrule-baseline.yaml
sleep 35
```

---

### Step 3 — `idleTimeout` (slow client)

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client-slow.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/03-destinationrule-baseline.yaml
oc rollout status deployment/grpc-client -n ossm-playground-apps --timeout=120s
sleep 90
```

**Before:** `./check.sh connections 90s` → **REUSING TCP**  
**Apply:** `oc apply -f garanti-labs/lab1-grpc/manifests/07-destinationrule-idle-timeout.yaml` → `sleep 90`  
**After:** `./check.sh connections 90s` → **NEW TCP EVERY REQUEST** (10s gap > 5s idle)

---

### Step 4 — `tcpKeepalive` (reuse returns)

**Apply:** `oc apply -f garanti-labs/lab1-grpc/manifests/04-destinationrule-tcp-keepalive.yaml` → `sleep 90`  
**After:** `./check.sh connections 90s` → **REUSING TCP** again (contrast with Step 3)

---

### Step 5 — `http2MaxRequests` (concurrent limit)

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client-concurrent.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/03-destinationrule-baseline.yaml
oc rollout status deployment/grpc-client -n ossm-playground-apps --timeout=120s
sleep 45
```

**Before:** `./check.sh errors` → **OK**  
**Apply:** `oc apply -f garanti-labs/lab1-grpc/manifests/08-destinationrule-http2-max-requests.yaml` → `sleep 35`  
**After:** `./check.sh errors` → **ERRORS**  
**Restore DR:** `oc apply -f garanti-labs/lab1-grpc/manifests/03-destinationrule-baseline.yaml`

---

### Step 6 — Wrong port name (imbalance)

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client-single-conn.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/01b-grpc-echo-wrong-port.yaml
sleep 60
```

**Before:** `./check.sh pods` → **BAD — one pod**  
**Fix:** `oc apply -f garanti-labs/lab1-grpc/manifests/01-grpc-echo.yaml` → `sleep 60`  
**After:** `./check.sh pods` → **GOOD**

Service port must be named **`grpc`** (or `appProtocol: grpc`).

---

### Step 7 — Ingress `protocol: GRPC`

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/09-gateway-grpc.yaml
GW_POD=$(oc get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n istio-system "$GW_POD" 18081:8081 &
```

**Wrong:** `oc apply -f garanti-labs/lab1-grpc/manifests/09b-gateway-wrong-protocol.yaml` → `./test-gateway-grpc.sh` → **FAIL**  
**Right:** `oc apply -f garanti-labs/lab1-grpc/manifests/09-gateway-grpc.yaml` → `./test-gateway-grpc.sh` → **OK**

---

### Step 8 — Say out loud (no demo)

- **Ingress 2 MB** — not default; set on gateway if needed  
- **App + Envoy both tune keepalive/idle** — pick one owner (DR), or get `UNAVAILABLE`  
- **Proxy broken but app healthy** — check `:15021` readiness on `istio-proxy`  
- **One DestinationRule per service host** — no duplicate DRs in same namespace

---

### Restore & cleanup

```bash
oc apply -f garanti-labs/lab1-grpc/manifests/02-grpc-client.yaml
oc apply -f garanti-labs/lab1-grpc/manifests/03-destinationrule-baseline.yaml
oc delete -f garanti-labs/lab1-grpc/manifests/09-gateway-grpc.yaml --ignore-not-found
oc delete -f garanti-labs/lab1-grpc/manifests/09b-gateway-wrong-protocol.yaml --ignore-not-found
oc delete -f garanti-labs/lab1-grpc/manifests/ --ignore-not-found
```

**Talking points:** [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md)


---

## Lab 2 — Key mesh metrics (Q4)

**Customer question:** What Istio/OpenShift metrics to use for throughput, errors, latency, and capacity at scale.

**Prereq:** Lab 0 Phase 5+ (PodMonitor + Telemetry metrics).

**Deploys:** Nothing extra — uses Bookinfo from Lab 0.

### Generate traffic

```bash
ROUTE=$(oc get route productpage -n ossm-playground-apps -o jsonpath='{.spec.host}')
for i in $(seq 1 30); do curl -sf "https://${ROUTE}/productpage" -o /dev/null; done
```

Wait ~1 minute, then run queries below in **Observe → Metrics**.

### PromQL cheat sheet

**Request volume (req/s per workload):**

```promql
sum(rate(istio_requests_total{
  destination_workload_namespace="ossm-playground-apps",
  reporter="destination"
}[5m])) by (destination_workload)
```

**Error rate (fraction of 5xx):**

```promql
sum(rate(istio_requests_total{
  destination_workload_namespace="ossm-playground-apps",
  response_code=~"5..",
  reporter="destination"
}[5m]))
/
sum(rate(istio_requests_total{
  destination_workload_namespace="ossm-playground-apps",
  reporter="destination"
}[5m]))
```

**Latency p99** — server proxy **+** app (not proxy-only ms):

```promql
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{
    destination_workload_namespace="ossm-playground-apps",
    reporter="destination"
  }[5m])) by (le, destination_workload)
)
```

**Source → destination:**

```promql
sum(rate(istio_requests_total{
  destination_workload_namespace="ossm-playground-apps",
  source_workload="productpage-v1",
  reporter="destination"
}[5m])) by (destination_workload, response_code)
```

**Proxy CPU / memory:**

```promql
sum(rate(container_cpu_usage_seconds_total{
  namespace="ossm-playground-apps",
  container="istio-proxy"
}[5m])) by (pod)

sum(container_memory_working_set_bytes{
  namespace="ossm-playground-apps",
  container="istio-proxy"
}) by (pod)
```

**Control plane (istiod):**

```promql
sum(rate(process_cpu_seconds_total{container="discovery"}[5m]))
sum(container_memory_working_set_bytes{container="discovery"})
rate(pilot_xds_pushes[5m])
rate(pilot_xds_push_errors[5m])
```

### Exercise

1. Screenshot Kiali graph + three queries (volume, errors, p99).
2. Note: `reporter=destination` = server proxy + app (mixed).
3. Note: Istio metrics **cannot** give per-request Envoy ms → use Lab 3 access logs.

### What metrics cannot do

| Need | Use instead |
|------|-------------|
| Per-hop Envoy ms | Access logs (Lab 3) or traces |
| App-only time | App instrumentation or server inbound access log |
| Universal mesh overhead number | Meshed vs non-meshed pilot (Lab 3) |
| `source p99 − destination p99` as proxy overhead | **Do not** — percentiles do not subtract cleanly |

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 2.

---

## Lab 3 — Sidecar latency (Q6)

**Customer question:** How much latency does the sidecar add? How to measure proxy vs app vs network?

**Prereq:** Lab 0 Phases 7–8 (tracing + access logs).

**Deploys (optional Part C only):** `lab3-latency/manifests/` — echo in meshed vs plain namespace.

### Part A — Access logs (per-hop proxy ms)

Browse productpage, then:

```bash
DETAILS=$(oc get pod -n ossm-playground-apps -l app=details -o jsonpath='{.items[0].metadata.name}')
oc logs "$DETAILS" -n ossm-playground-apps -c istio-proxy --tail=5

PP=$(oc get pod -n ossm-playground-apps -l app=productpage -o jsonpath='{.items[0].metadata.name}')
oc logs "$PP" -n ossm-playground-apps -c istio-proxy --tail=5
```

| Hop | Formula |
|-----|---------|
| **Server inbound** | `duration − upstream_service_time` ≈ Envoy ms; `upstream_service_time` ≈ app time |
| **Client outbound** | Same formula ≈ client proxy ms; upstream includes **network + server**, not app-only |

### Part B — Tracing

Kiali → Traces (`ossm-playground-apps`, last 15 min). Sum **`istio-proxy`** span durations ≈ proxy time in that trace.

### Part C — Optional: meshed vs plain total delta

**Low load only** on shared clusters.

```bash
oc apply -f garanti-labs/lab3-latency/manifests/
oc rollout status deployment/echo -n ossm-playground-perf --timeout=120s
oc rollout status deployment/echo -n ossm-playground-apps --timeout=120s

# Non-meshed target
oc exec -n ossm-playground-apps deploy/productpage-v1 -c productpage -- \
  fortio load -c 2 -qps 10 -duration 30s http://echo.ossm-playground-perf.svc.cluster.local:8080/

# Meshed target
oc exec -n ossm-playground-apps deploy/productpage-v1 -c productpage -- \
  fortio load -c 2 -qps 10 -duration 30s http://echo.ossm-playground-apps.svc.cluster.local:8080/
```

Compare Fortio **p50/p99** — total mesh delta for that path only.

```bash
oc delete -f garanti-labs/lab3-latency/manifests/ --ignore-not-found
```

### What to tell Garanti

- No metric named `mesh_overhead_milliseconds`.
- Proxy ms → access logs + traces; fleet trends → Lab 2 histograms.
- No universal RH benchmark script — your workload, fixed QPS, pilot namespace.

---

## Lab 4 — Mesh ↔ non-mesh & webhooks (Q8)

**Customer question:** Meshed pods calling plain services, webhooks, ServiceEntry, Sidecar egress.

**Prereq:** Lab 0 — meshed Bookinfo.

### What you deploy

| Manifest | Accomplishes |
|----------|--------------|
| `01-plain-namespace.yaml` | `ossm-playground-plain` without injection |
| `02-plain-httpbin.yaml` | HTTP backend in plain NS |
| `03-serviceentry-httpbin.yaml` | Register plain host in mesh |
| `04-sidecar-tight-egress.yaml` | **Block** egress not in allow list |
| `05-sidecar-allow-httpbin.yaml` | **Allow** httpbin again |
| `06-webhook-simulator.yaml` | Internal callback / webhook pattern |

### Steps

```bash
oc apply -f garanti-labs/lab4-nonmesh/manifests/01-plain-namespace.yaml
oc apply -f garanti-labs/lab4-nonmesh/manifests/02-plain-httpbin.yaml
oc rollout status deployment/httpbin -n ossm-playground-plain --timeout=120s

# Ex 1 — meshed → plain
oc exec -n ossm-playground-apps deploy/productpage-v1 -c productpage -- \
  curl -sf http://httpbin.ossm-playground-plain.svc.cluster.local/get -o /dev/null -w '%{http_code}\n'

# Ex 2 — ServiceEntry
oc apply -f garanti-labs/lab4-nonmesh/manifests/03-serviceentry-httpbin.yaml
# retest curl

# Ex 3 — Sidecar egress
oc apply -f garanti-labs/lab4-nonmesh/manifests/04-sidecar-tight-egress.yaml
# curl should fail until:
oc apply -f garanti-labs/lab4-nonmesh/manifests/05-sidecar-allow-httpbin.yaml

# Ex 4 — webhook pattern (not apiserver webhooks)
oc apply -f garanti-labs/lab4-nonmesh/manifests/06-webhook-simulator.yaml
oc rollout status deployment/webhook-simulator -n ossm-playground-plain --timeout=120s
oc exec -n ossm-playground-apps deploy/productpage-v1 -c productpage -- \
  curl -sf http://webhook-simulator.ossm-playground-plain.svc.cluster.local/health
```

Document curl results under **PERMISSIVE** mTLS (default). Do not switch cluster-wide **STRICT** without team OK.

### Cleanup

```bash
oc delete -f garanti-labs/lab4-nonmesh/manifests/05-sidecar-allow-httpbin.yaml --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/04-sidecar-tight-egress.yaml --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/03-serviceentry-httpbin.yaml --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/06-webhook-simulator.yaml --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/02-plain-httpbin.yaml --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/01-plain-namespace.yaml --ignore-not-found
```

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 4.

---

## Lab 5 — Retry policy (Q9)

**Customer question:** Impact of disabling retries globally.

**Prereq:** Lab 0 — Bookinfo meshed. Fault on **productpage → reviews** (reviews-v2 only).

| Manifest | Accomplishes |
|----------|--------------|
| `01-fault-abort-default.yaml` | 50% abort — default retry behavior |
| `02-fault-abort-no-retry.yaml` | Retries **off** — immediate 503 |
| `03-fault-abort-with-retry.yaml` | Retries **on** — extra upstream attempts |

```bash
oc apply -f garanti-labs/lab5-retry/manifests/01-fault-abort-default.yaml
```

Refresh productpage many times. **PromQL** (compare across steps 1–3):

```promql
sum(rate(istio_requests_total{
  destination_workload="reviews-v2",
  reporter="destination",
  response_flags=~".*"
}[2m])) by (response_code, response_flags)
```

Look for retry-related flags (`UO`, `UR`) when retries are enabled.

```bash
oc apply -f garanti-labs/lab5-retry/manifests/02-fault-abort-no-retry.yaml
oc apply -f garanti-labs/lab5-retry/manifests/03-fault-abort-with-retry.yaml
```

### Cleanup

```bash
oc delete virtualservice reviews -n ossm-playground-apps --ignore-not-found
```

**Important before Lab 8:** run this cleanup if `VirtualService/reviews` exists.

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 5.

---

## Lab 6 — Gateway protocols (Q10)

**Customer question:** HTTP/1.1 vs HTTP/2 vs gRPC on ingress.

**Prereq:** Lab 0. Optional: Lab 1 grpc-echo for gRPC gateway test.

Coordinate on shared clusters — use a **unique hostname** or port-forward only.

### Option A — Hands-on

```bash
oc apply -f garanti-labs/lab6-gateway/manifests/

GW_POD=$(oc get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n istio-system "$GW_POD" 18080:8080 18081:8081

curl -v --http1.1 "http://127.0.0.1:18080/productpage"
curl -v --http2 "http://127.0.0.1:18080/productpage"
grpcurl -plaintext 127.0.0.1:18081 list   # needs Lab 1 grpc-echo running
```

Gateways may default to **HTTP/1.1** unless port protocol is **`grpc`** or **`http2`**.

### Option B — Read-only

```bash
GW_POD=$(oc get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config listener "$GW_POD" -n istio-system
istioctl proxy-config route "$GW_POD" -n istio-system
```

### Cleanup

```bash
oc delete -f garanti-labs/lab6-gateway/manifests/ --ignore-not-found
```

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 6.

---

## Lab 7 — Envoy logging & recovery (Q11)

**Customer question:** Safe logging in production; proxy vs app health.

**Prereq:** Lab 0 Phase 8 (access logs via `istio-system` Telemetry).

**Deploys:** Nothing new.

### Part A — Access logs (production pattern)

```bash
oc logs -n ossm-playground-apps -l app=details -c istio-proxy --tail=3
```

### Part B — Brief debug on ONE pod (2 minutes max)

```bash
POD=$(oc get pod -n ossm-playground-apps -l app=details -o jsonpath='{.items[0].metadata.name}')
oc annotate pod "$POD" -n ossm-playground-apps sidecar.istio.io/logLevel=debug --overwrite
# browse productpage a few times
sleep 120
oc annotate pod "$POD" -n ossm-playground-apps sidecar.istio.io/logLevel-
```

Observe log volume / proxy CPU — **never** mesh-wide debug.

### Part C — Proxy readiness vs app liveness

```bash
oc exec -n ossm-playground-apps "$POD" -c istio-proxy -- curl -sf localhost:15021/healthz/ready && echo "proxy ready"
oc get pod "$POD" -n ossm-playground-apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 7.

---

## Lab 8 — VS/DR lifecycle (Q12)

**Customer question:** Deleting VirtualService / DestinationRule causes brief degraded routing and istiod churn.

**Prereq:** Lab 0. **Run Lab 5 cleanup first** if `VirtualService/reviews` exists.

| Manifest | Accomplishes |
|----------|--------------|
| `01-reviews-v1.yaml` | Second reviews version for canary |
| `02-canary-vs-dr.yaml` | 90% v1 / 10% v2 routing |

```bash
oc apply -f garanti-labs/lab8-lifecycle/manifests/01-reviews-v1.yaml
oc rollout status deployment/reviews-v1 -n ossm-playground-apps --timeout=180s
oc apply -f garanti-labs/lab8-lifecycle/manifests/02-canary-vs-dr.yaml
```

Refresh productpage — mostly plain reviews (v1), occasionally stars (v2).

### PromQL — run while deleting/applying

```promql
rate(pilot_xds_pushes[1m])
rate(pilot_xds_push_errors[1m])
sum(rate(istio_requests_total{
  destination_workload_namespace="ossm-playground-apps",
  response_code=~"5..",
  reporter="destination"
}[1m]))
```

| Query | What it shows |
|-------|---------------|
| `pilot_xds_pushes` | Config push rate — **spikes** during churn |
| `pilot_xds_push_errors` | Push failures — should stay ~0 |
| `5xx rate` | User-visible errors during delete window |

### Exercises

```bash
# Ex 1 — delete DR first
oc delete destinationrule reviews-canary -n ossm-playground-apps
# browse ~30s, then:
oc apply -f garanti-labs/lab8-lifecycle/manifests/02-canary-vs-dr.yaml

# Ex 2 — delete VS first
oc delete virtualservice reviews-canary -n ossm-playground-apps
oc apply -f garanti-labs/lab8-lifecycle/manifests/02-canary-vs-dr.yaml

# Ex 3 — rapid apply/delete
for i in $(seq 1 10); do
  oc delete -f garanti-labs/lab8-lifecycle/manifests/02-canary-vs-dr.yaml --ignore-not-found
  sleep 2
  oc apply -f garanti-labs/lab8-lifecycle/manifests/02-canary-vs-dr.yaml
  sleep 2
done
```

### Cleanup

```bash
oc delete -f garanti-labs/lab8-lifecycle/manifests/ --ignore-not-found
oc delete deployment/reviews-v1 -n ossm-playground-apps --ignore-not-found
```

### What to tell Garanti

See [notes/Garanti-talking-points.md](notes/Garanti-talking-points.md) — Lab 8.

---

## Suggested schedule

| Session | Labs | ~Time |
|---------|------|-------|
| 1 | Lab 0 (Phases 1–5) | 2 h |
| 2 | Lab 0 (Phases 6–8) + Lab 2 | 1.5 h |
| 3 | Lab 3 + Lab 5 | 1.5 h |
| 4 | Lab 1 | 45 min |
| 5 | Lab 4 + Lab 8 | 2 h |
| 6 | Lab 6 + Lab 7 | 1.5 h |

---

## Cleanup (all labs)

```bash
oc delete -f garanti-labs/lab8-lifecycle/manifests/ --ignore-not-found
oc delete -f garanti-labs/lab5-retry/manifests/ --ignore-not-found
oc delete -f garanti-labs/lab1-grpc/manifests/ --ignore-not-found
oc delete -f garanti-labs/lab3-latency/manifests/ --ignore-not-found
oc delete -f garanti-labs/lab4-nonmesh/manifests/ --ignore-not-found
oc delete -f garanti-labs/lab6-gateway/manifests/ --ignore-not-found
oc delete namespace ossm-playground-plain ossm-playground-perf --ignore-not-found
```

Observability workshop cleanup: [observability/README.md](../observability/README.md).

---

## PromQL quick reference

| Lab | Query purpose | When to run |
|-----|---------------|-------------|
| 1 | `istio_requests_total` by `pod` for grpc-echo (`pod=~"grpc-echo-.*"`) | Client running 1–2 min; `reporter="destination"`; **not** `destination_pod` |
| 2 | Volume, errors, p99, proxy CPU/mem, istiod | After curling productpage 30×; wait 1 min |
| 5 | `reviews-v2` by `response_code`, `response_flags` | While refreshing productpage during fault steps |
| 8 | `pilot_xds_pushes`, push errors, 5xx rate | While deleting/applying VS/DR |

**Where:** OpenShift Console → **Observe → Metrics** → paste → **Run** → **Table** for labels.

**Double-counting:** without `reporter="destination"`, request rates are ~2× (source + destination sidecars both emit `istio_requests_total`).

**Per-pod breakdown:** use `by (pod)` on metrics scraped from each `istio-proxy` — not `by (destination_pod)` (that label is not in standard Istio metrics and returns a single aggregated row).

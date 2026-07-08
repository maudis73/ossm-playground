# Garanti — personal talking points

Fill in **What I saw** after each lab. **What I'd tell Garanti** is pre-drafted — adjust with your numbers.

**Runbook:** [../README.md](../README.md)

---

## Lab 0 — Foundation

**What I saw:**
- (pods 2/2, Kiali graph, trace ID, access log fields)

**What I'd tell Garanti:**
- Pilot namespace first; global Telemetry + PodMonitor per namespace.

---

## Lab 1 — gRPC (Q3, Q5, Q10)

**What I saw:**
- `./check.sh pods` → GOOD (3 pods)
- `./check.sh connections` → ~6 REUSE → ~150 churn (maxReq=1) → ~3 capped (maxConnections=1)
- `./check.sh pods` → BAD then GOOD (wrong port name fix)
- `./test-gateway-grpc.sh` → FAIL then OK

**What I'd tell Garanti:**
- Mesh picks the **pod per RPC**; DR picks **when to recycle TCP** — different knobs.
- `maxRequestsPerConnection: 1` = churn, **not** “enable load balancing.”
- `tcp.maxConnections: 1` = **one wire per pod** (≈3 total with 3 replicas), reuse OK.
- Service port **`grpc`** required for L7 spread.
- Gateway needs **`protocol: GRPC`** for ingress gRPC.
- One DR owner per host; remove duplicate app keepalive/idle.

---

## Lab 2 — Key metrics (Q4)

**What I saw:**
- (screenshot queries)

**What I'd tell Garanti:**
- `istio_requests_total` + histograms for SLOs; `reporter=destination` for server view.

---

## Lab 3 — Sidecar latency (Q6)

**What I saw:**
- (access logs / traces)

**What I'd tell Garanti:**
- No `mesh_overhead_ms` metric — logs + traces for proxy time.

---

## Lab 4 — Non-mesh access (Q8)

**What I saw:**
- (curl / Sidecar / webhook)

**What I'd tell Garanti:**
- Meshed→plain needs planning under STRICT; ServiceEntry + Sidecar egress.

---

## Lab 5 — Retry policy (Q9)

**What I saw:**
- (503 with/without retries)

**What I'd tell Garanti:**
- Retries on VirtualService caller — cap attempts.

---

## Lab 6 — Gateway protocols (Q10)

**What I saw:**
- (HTTP/1.1 vs HTTP/2 / grpcurl)

**What I'd tell Garanti:**
- Declare protocol on Gateway ports.

---

## Lab 7 — Envoy logging (Q11)

**What I saw:**
- (namespace logs, single-pod debug)

**What I'd tell Garanti:**
- Debug one pod only; proxy `:15021` readiness matters.

---

## Lab 8 — VS/DR lifecycle (Q12)

**What I saw:**
- (delete churn, pilot_xds_pushes)

**What I'd tell Garanti:**
- Watch istiod during bulk config changes.

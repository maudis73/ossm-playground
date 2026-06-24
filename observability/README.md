# Observability workshop — OpenShift Service Mesh 3

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

Build mesh observability step by step: **metrics** (Kiali graph), **distributed tracing** (Tempo), and **Envoy access logs** — all on a classic **sidecar** dataplane.

Run `oc apply` commands from the **repository root** (paths below are repo-relative).

**Workshop rule:** once a phase is committed, its manifest files under `observability/manifests/` are **immutable**. Later capabilities get **new numbered files** only.

## What you will cover

| Signal | Phases | Where it appears |
|--------|--------|------------------|
| **Metrics** | 5 | Kiali **Graph** (Prometheus via `istio-proxy`) |
| **Traces** | 6–7 | Kiali **Traces** (Tempo) |
| **Access logs** | 8 | Kiali **Proxy logs** on each workload |

All Bookinfo services run as **sidecar-injected** pods in **`ossm-playground-apps`**.

## Observability pipeline (end state)

```
istio-proxy  ──metrics──►  Prometheus (OpenShift user workload monitoring)
       │
       ├──OTLP :4317──►  otel-collector  ──►  TempoStack  ──►  MinIO (S3 storage)
       │
       └──access logs──►  proxy stdout  ──►  Kiali Logs

Kiali  ──queries──►  Thanos (metrics)  +  Tempo :3200 (traces)
```

- **`Telemetry`** tells Envoy what to emit; **`PodMonitor`** tells Prometheus what to scrape.
- **TempoStack** is the trace backend; **MinIO** is its object storage (cluster prerequisite, not deployed here).

## Phase overview

| Phase | Topic |
|-------|--------|
| 1 | Deploy Bookinfo (outside the mesh) |
| 2 | Istio CNI |
| 3 | Control plane (`Istio/default`) |
| 4 | Enroll app namespace (sidecar injection) |
| 5 | Metrics + Kiali graph |
| 6 | Tracing backend (Tempo + OTel collector) |
| 7 | Enable tracing on the mesh |
| 8 | Envoy access logs |

## Prerequisites

**Phases 1–5:** cluster admin access, Sail / OSSM operator, Istio CNI operator, **Kiali operator**, OpenShift **user workload monitoring** enabled.

**Phases 6–8:** also **Tempo operator**, **OpenTelemetry operator**, and shared **MinIO** in the `minio` namespace (trace storage).

## The application

| Service | Role |
|---------|------|
| **productpage** | Web UI — open in the browser |
| **details** | Backend — **Book Details** table |
| **reviews-v2** | Backend — **Book Reviews** (black star ratings) |
| **ratings** | Backend — star ratings API (called by reviews) |

**productpage** calls **details** and **reviews** on each page load. Mesh traffic path: `productpage → details`, `productpage → reviews → ratings`.

Namespace: **`ossm-playground-apps`**

---

## Phase 1 — Deploy apps (outside the mesh)

```bash
oc apply -f observability/manifests/01-apps-namespace.yaml
oc apply -f observability/manifests/02-bookinfo.yaml
oc apply -f observability/manifests/03-route.yaml
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
```

**Show:** pods are **1/1** (no sidecar). Open the app:

```bash
echo "https://$(oc get route productpage -n ossm-playground-apps -o jsonpath='{.spec.host}')/productpage"
```

**Say:** applications run fine without the mesh; the operator does not inject sidecars by itself.

---

## Phase 2 — Istio CNI

Skip if `IstioCNI/default` is already Healthy on the cluster.

```bash
oc apply -f observability/manifests/04-istio-cni-namespace.yaml
oc apply -f observability/manifests/05-istio-cni-default.yaml
oc wait istiocni/default --for=condition=Ready --timeout=300s
```

**Show:** CNI DaemonSet Running in `istio-cni`.

**Say:** on OpenShift, CNI handles traffic redirect — no privileged `istio-init` init container.

---

## Phase 3 — Default control plane

Minimal `Istio/default` — discovery selectors only, no tracing yet.

```bash
oc apply -f observability/manifests/06-control-plane-namespace.yaml
oc apply -f observability/manifests/07-istio-default.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc get pods -n maurizio-istio-system -l istio=pilot
```

**Show:** `istiod` Healthy. App pods are still **1/1**.

**Say:** only namespaces labeled `istio-discovery=enabled` are in scope for this control plane.

---

## Phase 4 — Enroll the app namespace

```bash
oc apply -f observability/manifests/08-apps-mesh-enroll.yaml
oc rollout restart deployment -n ossm-playground-apps
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
oc get pods -n ossm-playground-apps
```

**Show:** pods are **2/2** (`app` + `istio-proxy`).

**Say:** `istio-discovery=enabled` scopes the namespace to `istiod`; `istio.io/rev=default` enables sidecar injection. Existing pods need a restart after labeling.

---

## Phase 5 — Monitoring (metrics / Kiali graph)

Kiali’s **Graph** uses **Prometheus metrics** scraped from `istio-proxy`. On OpenShift this requires a **ServiceMonitor** for `istiod` and a **PodMonitor** in the app namespace.

```bash
oc apply -f observability/manifests/09-istiod-servicemonitor.yaml
oc apply -f observability/manifests/10-podmonitor.yaml
oc apply -f observability/manifests/11-telemetry-metrics.yaml
oc apply -f observability/manifests/12-kiali.yaml
```

Refresh productpage several times, wait ~1 minute, then open Kiali → namespace **ossm-playground-apps** → **Graph**.

```bash
echo "https://$(oc get route kiali -n maurizio-istio-system -o jsonpath='{.spec.host}')"
```

**Show:** edges **productpage → details**, **productpage → reviews → ratings**; request rates on the graph. No traces yet.

**Say:** `Telemetry` enables Prometheus-format stats on proxies; `PodMonitor` tells OpenShift Prometheus where to scrape. The mesh works without scraping, but Kiali has nothing to draw.

---

## Phase 6 — Tracing backend (Tempo + OTel collector)

Deploy the tracing pipeline. Proxies are **not** sending spans yet.

```bash
oc apply -f observability/manifests/13-tempostack-namespace.yaml
oc apply -f observability/manifests/14-minio-traces-secret.yaml
oc apply -f observability/manifests/15-tempostack.yaml
oc apply -f observability/manifests/16-otel-collector.yaml
```

Wait until `TempoStack/simplest` is Ready and `OpenTelemetryCollector/otel` is `1/1`.

If Kiali **Traces** later show `connection refused` on `:3200`, apply the oauth-proxy CPU fix:

```bash
oc apply -f observability/manifests/21-tempostack-oauth-proxy-resources.yaml
```

**Show:** Tempo and collector pods Running; Kiali **Traces** tab still empty.

**Say:** TempoStack is the trace **backend**; MinIO (already on the cluster) is **storage**. The mesh sends spans to the OTel collector only after Phase 7.

---

## Phase 7 — Enable tracing on the mesh

Sidecars export spans **OTLP :4317** → `otel-collector` → Tempo. Kiali queries Tempo on **:3200**.

```bash
oc apply -f observability/manifests/17-istio-tracing.yaml
oc apply -f observability/manifests/18-telemetry-tracing.yaml
oc apply -f observability/manifests/19-kiali-tracing.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc rollout restart deployment -n ossm-playground-apps
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
```

Refresh productpage **10–15 times**, wait ~30s, then Kiali → **ossm-playground-apps** → **Traces** (range: **Last 1 hour**).

```bash
echo "https://$(oc get route kiali -n maurizio-istio-system -o jsonpath='{.spec.host}')"
```

**Show:** spans for `productpage → details`, `productpage → reviews → ratings`.

**Say:** the `Istio` CR defines the `otel` extension provider (collector address); `Telemetry` must reference the same provider name. Proxies need a restart to pick up `meshConfig`.

---

## Phase 8 — Access logs

Envoy access logs go to **istio-proxy stdout** (built-in `envoy` provider). View them in Kiali **Logs** and correlate with traces.

```bash
oc apply -f observability/manifests/20-telemetry-accesslogs.yaml
```

Refresh productpage several times, then Kiali → **Workloads** → **productpage-v1** → **Logs** → **Proxy logs**. Enable **Spans** to overlay trace markers on the timeline.

**Show:** HTTP access lines (`GET /productpage`, `GET /details`, …) with response codes and `duration`.

**Say:** access logs are per-hop proxy output — one line per request per proxy. With tracing enabled, Kiali aligns logs and spans by time. This completes the sidecar observability story: **graph, traces, logs**.

For **ambient dataplane** observability (ztunnel, waypoints, cross-mode traffic), continue with the **[ambient workshop](../ambient/README.md)** (planned).

---

## Appendix — mesh latency benchmark (optional)

See **[docs/MESH-LATENCY-BENCHMARK.md](docs/MESH-LATENCY-BENCHMARK.md)** for methodology and sample results.

```bash
chmod +x observability/scripts/bench-mesh-latency.sh
./observability/scripts/bench-mesh-latency.sh -n 30 --sleep 15
# burst: ./observability/scripts/bench-mesh-latency.sh -n 100 --parallel 100 --sleep 30 -o observability/docs/mesh-latency-results-raw.md
```

The script correlates **curl wall time**, **proxy access-log duration**, and **Tempo span duration** per request.

---

## Manifest index

| File | Phase | Purpose |
|------|-------|---------|
| `observability/manifests/01-apps-namespace.yaml` | 1 | App namespace (`openshift.io/cluster-monitoring`) |
| `observability/manifests/02-bookinfo.yaml` | 1 | productpage, details, reviews-v2, ratings |
| `observability/manifests/03-route.yaml` | 1 | OpenShift Route to productpage |
| `observability/manifests/04-istio-cni-namespace.yaml` | 2 | CNI namespace |
| `observability/manifests/05-istio-cni-default.yaml` | 2 | `IstioCNI/default` |
| `observability/manifests/06-control-plane-namespace.yaml` | 3 | `maurizio-istio-system` namespace |
| `observability/manifests/07-istio-default.yaml` | 3 | `Istio/default` — discovery selectors |
| `observability/manifests/08-apps-mesh-enroll.yaml` | 4 | Mesh labels on app namespace |
| `observability/manifests/09-istiod-servicemonitor.yaml` | 5 | Scrape `istiod` metrics |
| `observability/manifests/10-podmonitor.yaml` | 5 | Scrape `istio-proxy` metrics |
| `observability/manifests/11-telemetry-metrics.yaml` | 5 | `Telemetry/default` — Prometheus metrics |
| `observability/manifests/12-kiali.yaml` | 5 | Kiali — graph (Thanos), tracing off |
| `observability/manifests/13-tempostack-namespace.yaml` | 6 | `tempostack` namespace |
| `observability/manifests/14-minio-traces-secret.yaml` | 6 | S3 secret for Tempo (MinIO backend) |
| `observability/manifests/15-tempostack.yaml` | 6 | `TempoStack/simplest` |
| `observability/manifests/16-otel-collector.yaml` | 6 | `OpenTelemetryCollector/otel` → Tempo |
| `observability/manifests/21-tempostack-oauth-proxy-resources.yaml` | 6b | oauth-proxy CPU fix (Kiali `:3200`) |
| `observability/manifests/17-istio-tracing.yaml` | 7 | `Istio/default` — OTLP extension provider |
| `observability/manifests/18-telemetry-tracing.yaml` | 7 | `Telemetry/default` — OTLP tracing |
| `observability/manifests/19-kiali-tracing.yaml` | 7 | Kiali — enable Tempo tracing |
| `observability/manifests/20-telemetry-accesslogs.yaml` | 8 | `Telemetry/default` — Envoy access logs |
| `observability/scripts/bench-mesh-latency.sh` | — | Optional latency benchmark |
| `observability/docs/MESH-LATENCY-BENCHMARK.md` | — | Benchmark methodology |

---

## Cleanup

```bash
oc delete namespace ossm-playground-apps tempostack
# Optional: leave Istio/default and CNI if shared cluster infrastructure
```

---

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)

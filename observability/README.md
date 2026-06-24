# Observability workshop — OpenShift Service Mesh 3

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

Each phase is a separate `oc apply` moment — capabilities are added gradually (mesh → metrics → tracing backend → tracing → access logs → ambient ratings).

Run `oc apply` commands from the **repository root** (paths below are repo-relative).

**Workshop rule:** once a phase is committed, its manifest files under `observability/manifests/` are **immutable**. Later capabilities get **new numbered files** only.

## Prerequisites

**Through Phase 5:** cluster admin access, Sail / OSSM operator, Istio CNI operator, **Kiali operator**.

**Phase 6+:** also **Tempo operator**, **OpenTelemetry operator**, and shared **MinIO** in the `minio` namespace (trace storage).

**Phase 9+:** cluster admin to install **ztunnel**; **OVN-Kubernetes** CNI is recommended for ambient on OpenShift.

## The application

| Service | Role |
|---------|------|
| **productpage** | Web UI — open in the browser |
| **details** | Backend — **Book Details** table |
| **reviews-v2** | Backend — **Book Reviews** (black star ratings) |
| **ratings** | Backend — called by reviews-v2 for star display (**Phase 9:** moves to `ossm-playground-ambient`, ambient + waypoint) |

**productpage** calls **details** and **reviews** on each page load. Traffic path in the mesh: `productpage → details`, `productpage → reviews → ratings` (after Phase 9, **ratings** runs in **`ossm-playground-ambient`**).

Namespaces: **`ossm-playground-apps`** (sidecar workloads) · **`ossm-playground-ambient`** (ratings, Phase 9+)

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

**Say:** apps run fine without the mesh; the operator does not inject sidecars by itself.

---

## Phase 2 — Istio CNI

Skip if `IstioCNI/default` is already Healthy on the cluster.

```bash
oc apply -f observability/manifests/04-istio-cni-namespace.yaml
oc apply -f observability/manifests/05-istio-cni-default.yaml
oc wait istiocni/default --for=condition=Ready --timeout=300s
```

**Show:** CNI daemonset Running in `istio-cni`.

**Say:** CNI is required for sidecar injection on OpenShift (no privileged `istio-init` init container).

---

## Phase 3 — Default control plane

Minimal `Istio/default` — discovery selectors only, no tracing or extension providers yet.

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

**Say:** `istio-discovery=enabled` scopes the namespace to `istiod`; `istio.io/rev=default` enables sidecar injection from `Istio/default`. Existing pods need a restart after labeling.

---

## Phase 5 — Monitoring (metrics / Kiali graph)

Kiali’s **Graph** uses **Prometheus metrics** from `istio-proxy`. On OpenShift, user workload monitoring needs a **ServiceMonitor** for `istiod` and a **PodMonitor** per meshed app namespace.

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

**Show:** edges **productpage → details**, **productpage → reviews → ratings**, request rates on the graph. No traces yet.

**Say:** the mesh works without PodMonitor, but Kiali has no traffic metrics to draw.

---

## Phase 6 — Tracing backend (Tempo + OTel collector)

Deploy the tracing pipeline. The mesh is **not** sending spans yet.

```bash
oc apply -f observability/manifests/13-tempostack-namespace.yaml
oc apply -f observability/manifests/14-minio-traces-secret.yaml
oc apply -f observability/manifests/15-tempostack.yaml
oc apply -f observability/manifests/16-otel-collector.yaml
```

Wait until `TempoStack/simplest` is Ready and `OpenTelemetryCollector/otel` is `1/1`.

If Kiali **Traces** later show `connection refused` on `:3200`, apply the oauth-proxy CPU fix (Phase 6b):

```bash
oc apply -f observability/manifests/21-tempostack-oauth-proxy-resources.yaml
```

**Show:** Tempo and collector pods Running; Kiali **Traces** tab still empty.

**Say:** backend is ready; sidecars are not configured to export spans until Phase 7.

---

## Phase 7 — Enable tracing on the mesh

Sidecars send spans **OTLP :4317** → `otel-collector` → Tempo. Kiali **Traces** queries Tempo on **:3200**.

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

**Show:** spans for `productpage` → `details`, `productpage` → `reviews` → `ratings`.

**Say:** `extensionProviders` name (`otel`) must match `Telemetry` tracing provider; proxies need a restart to pick up `meshConfig`.

---

## Phase 8 — Access logs

Envoy access logs go to **istio-proxy stdout** (built-in `envoy` provider). View them in Kiali **Logs** and correlate with traces.

```bash
oc apply -f observability/manifests/20-telemetry-accesslogs.yaml
```

Refresh productpage several times, then Kiali → **Workloads** → **productpage-v1** → **Logs** → **Proxy logs**. Enable **Spans** to overlay trace markers on the timeline.

**Show:** HTTP access lines (`GET /productpage`, `GET /details`, …) with response codes in proxy logs.

**Say:** access logs are per-hop proxy output; with tracing enabled, Kiali can align log lines and spans by time. App container logs are separate (Bookinfo writes little to stdout).

---

## Phase 9 — Ratings in ambient namespace

Move **ratings** to **`ossm-playground-ambient`** (ambient dataplane + **waypoint** for L7 observability). **productpage**, **details**, and **reviews** stay on **sidecars** in `ossm-playground-apps`. Same `Istio/default` control plane; two dataplane modes coexist.

### 9a — Enable ambient dataplane

```bash
oc apply -f observability/manifests/22-ztunnel-namespace.yaml
oc apply -f observability/manifests/23-istio-cni-ambient.yaml
oc apply -f observability/manifests/24-istio-ambient.yaml
oc apply -f observability/manifests/25-ztunnel-default.yaml
oc wait istio/default -n maurizio-istio-system --for=condition=Ready --timeout=300s
oc wait ztunnel/default -n ztunnel --for=condition=Ready --timeout=300s
oc get daemonset -n ztunnel
oc rollout restart deployment -n ossm-playground-apps
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
```

**Show:** `ztunnel` DaemonSet **READY** on all nodes; existing sidecar pods in `ossm-playground-apps` still **2/2**.

**Say:** `profile: ambient` adds **ztunnel** (per-node L4); sidecar namespaces are unchanged (`istio.io/rev: default`). Phase 7 tracing settings are preserved in `24-istio-ambient.yaml`. **`ISTIO_META_ENABLE_HBONE`** on sidecars (in `24`) is required later when **reviews** becomes an ambient pod in **9c** — restart workloads here so proxies pick it up.

### 9b — Deploy ratings in ambient + bridge DNS

```bash
oc apply -f observability/manifests/26-ratings-ambient-namespace.yaml
oc apply -f observability/manifests/27-ratings-waypoint.yaml
oc apply -f observability/manifests/28-ratings-deploy.yaml
oc rollout status deployment/ratings-v1 -n ossm-playground-ambient --timeout=180s
```

Remove the original ratings workload from the apps namespace (reviews hardcodes hostname `ratings` — we replace it with an ExternalName bridge next):

```bash
oc delete deployment ratings-v1 -n ossm-playground-apps --ignore-not-found
oc delete service ratings -n ossm-playground-apps --ignore-not-found
oc delete serviceaccount bookinfo-ratings -n ossm-playground-apps --ignore-not-found
oc apply -f observability/manifests/29-ratings-externalname-bridge.yaml
```

Smoke test — stars must still appear:

```bash
echo "https://$(oc get route productpage -n ossm-playground-apps -o jsonpath='{.spec.host}')/productpage"
```

**Show:** `ratings-v1` in `ossm-playground-ambient` is **1/1** (no sidecar); `ratings-waypoint` deployment exists; `Service/ratings` in `ossm-playground-apps` is type **ExternalName**.

**Say:** reviews still calls `http://ratings:9080`; ExternalName resolves to `ratings.ossm-playground-ambient.svc.cluster.local`. Traffic crosses namespaces over **HBONE** (reviews ztunnel → ratings waypoint → ratings pod).

### 9c — Observability for ambient namespace

```bash
oc apply -f observability/manifests/30-ambient-podmonitor.yaml
oc apply -f observability/manifests/31-ztunnel-podmonitor.yaml   # skip if PodMonitor already exists in ztunnel
oc apply -f observability/manifests/32-ratings-waypoint-telemetry.yaml
oc apply -f observability/manifests/33-reviews-ambient-client.yaml
oc rollout restart deployment/reviews-v2 -n ossm-playground-apps
oc rollout status deployment/reviews-v2 -n ossm-playground-apps --timeout=180s
```

Mesh-wide `Telemetry/default` (Phases 7–8) covers **sidecar** proxies only. Ambient **ratings** needs **`32`** (metrics + tracing + access logs on the waypoint) and **`30`** (PodMonitor to scrape waypoint stats into Prometheus).

**`33` is required for ratings traces:** if **reviews** keeps its sidecar, outbound HBONE goes **directly to the ratings pod** and **bypasses the waypoint** — waypoint access logs stay empty and traces stop at reviews. **`33`** runs **reviews** as an ambient pod (`istio.io/dataplane-mode: ambient` on the pod, no sidecar) so the path is **reviews → waypoint → ratings**. **Do not** label the whole `ossm-playground-apps` namespace ambient — that drops sidecars from **productpage**/**details** on rollout. **`24`** enables `ISTIO_META_ENABLE_HBONE` on remaining sidecars so **productpage → reviews** works across modes.

Refresh productpage **10–15 times**, wait ~30s, then Kiali:

- **Graph** → include **ossm-playground-ambient** → edge **reviews → ratings** (cross-namespace).
- **Workloads** → **ratings-v1** (1/1, no proxy container on app pod — **no traces tab** here).
- **Workloads** → **ratings-waypoint-…** → **Logs** → **Proxy logs** and **Traces** (L7 hop for ratings).
- **Traces** (from productpage or reviews) → span `ratings.ossm-playground-ambient.svc.cluster.local:9080/*` with service **`ratings-waypoint.ossm-playground-ambient`**.

**Say:** sidecar services use **istio-proxy** access logs (Phase 8); ambient **ratings** uses **waypoint** proxy logs and **ztunnel** for L4. Look at **ratings-waypoint**, not **ratings-v1**, for proxy telemetry.

### Appendix — mesh latency benchmark

See **[docs/MESH-LATENCY-BENCHMARK.md](docs/MESH-LATENCY-BENCHMARK.md)** for methodology, interpreted results (including a **100 parallel request** run), and consistent **avg / median / p95 / min / max** tables.

```bash
chmod +x observability/scripts/bench-mesh-latency.sh
./observability/scripts/bench-mesh-latency.sh -n 30 --sleep 15
# burst: ./observability/scripts/bench-mesh-latency.sh -n 100 --parallel 100 --sleep 30 -o observability/docs/mesh-latency-results-raw.md
```

Each request sends a unique `X-Request-Id` header. The script reports **avg / median / p95 / min / max** for:

| Report section | What it measures |
|----------------|------------------|
| **curl wall** | Client round-trip (TLS, route, network + mesh) |
| **productpage inbound proxy** | Mesh edge duration — meaningful end-to-end **inside** the mesh |
| **Per-hop proxy** | `duration` on each sidecar access-log line (inbound/outbound per service) |
| **Per-span (Tempo)** | Span duration when `guid:x-request-id` is indexed |
| **Span vs proxy** | Difference on the same hop — rough Envoy overhead |

**Reading the output:** compare median **curl wall** vs median **productpage inbound** to show latency outside the mesh. The **reviews** branch usually dominates inside the mesh. Do **not** sum hop or span averages for total time — `details` and `reviews` are called in parallel.

**Access log tip:** the request ID is the **quoted value** after `"curl/..."` in proxy logs — there is no `x-request-id=` label in the default Envoy format.

**Tempo tip:** if span rows are empty, increase `--sleep` (ingest/index lag) or reduce `-n`.

---

## Manifest index

| File | Purpose |
|------|---------|
| `observability/manifests/01-apps-namespace.yaml` | App namespace (no mesh labels) |
| `observability/manifests/02-bookinfo.yaml` | productpage, details, reviews-v2, ratings |
| `observability/manifests/03-route.yaml` | OpenShift Route to productpage |
| `observability/manifests/04-istio-cni-namespace.yaml` | CNI namespace |
| `observability/manifests/05-istio-cni-default.yaml` | `IstioCNI/default` |
| `observability/manifests/06-control-plane-namespace.yaml` | `maurizio-istio-system` namespace |
| `observability/manifests/07-istio-default.yaml` | `Istio/default` — discovery selectors only |
| `observability/manifests/08-apps-mesh-enroll.yaml` | Mesh labels on app namespace |
| `observability/manifests/09-istiod-servicemonitor.yaml` | Scrape `istiod` metrics (control plane) |
| `observability/manifests/10-podmonitor.yaml` | Scrape `istio-proxy` metrics (app workloads) |
| `observability/manifests/11-telemetry-metrics.yaml` | `Telemetry/default` — Prometheus metrics only |
| `observability/manifests/12-kiali.yaml` | Kiali — graph (Thanos), tracing disabled |
| `observability/manifests/13-tempostack-namespace.yaml` | `tempostack` namespace |
| `observability/manifests/14-minio-traces-secret.yaml` | S3 secret for Tempo (MinIO backend) |
| `observability/manifests/15-tempostack.yaml` | `TempoStack/simplest` |
| `observability/manifests/16-otel-collector.yaml` | `OpenTelemetryCollector/otel` → Tempo |
| `observability/manifests/21-tempostack-oauth-proxy-resources.yaml` | Raise oauth-proxy CPU (fixes Kiali `:3200` connection refused) |
| `observability/manifests/17-istio-tracing.yaml` | `Istio/default` — add OTLP extension provider |
| `observability/manifests/18-telemetry-tracing.yaml` | `Telemetry/default` — add OTLP tracing |
| `observability/manifests/19-kiali-tracing.yaml` | Kiali — enable Tempo tracing |
| `observability/manifests/20-telemetry-accesslogs.yaml` | `Telemetry/default` — add Envoy access logs |
| `observability/manifests/22-ztunnel-namespace.yaml` | `ztunnel` namespace |
| `observability/manifests/23-istio-cni-ambient.yaml` | `IstioCNI/default` — ambient profile |
| `observability/manifests/24-istio-ambient.yaml` | `Istio/default` — ambient profile + tracing |
| `observability/manifests/25-ztunnel-default.yaml` | `ZTunnel/default` |
| `observability/manifests/26-ratings-ambient-namespace.yaml` | `ossm-playground-ambient` namespace labels |
| `observability/manifests/27-ratings-waypoint.yaml` | Waypoint Gateway for ratings L7 |
| `observability/manifests/28-ratings-deploy.yaml` | ratings deployment in ambient namespace |
| `observability/manifests/29-ratings-externalname-bridge.yaml` | ExternalName `ratings` in apps namespace |
| `observability/manifests/30-ambient-podmonitor.yaml` | PodMonitor for waypoint proxies |
| `observability/manifests/31-ztunnel-podmonitor.yaml` | PodMonitor for ztunnel (if not already present) |
| `observability/manifests/32-ratings-waypoint-telemetry.yaml` | Waypoint Prometheus metrics + OTLP tracing + access logs |
| `observability/manifests/33-reviews-ambient-client.yaml` | Ambient reviews pod only (no sidecar) for ratings waypoint path |
| `observability/scripts/bench-mesh-latency.sh` | Optional — aggregate mesh vs client latency over N requests |
| `observability/docs/MESH-LATENCY-BENCHMARK.md` | Benchmark methodology and results |

---

## Cleanup

```bash
oc delete namespace ossm-playground-apps ossm-playground-ambient
# Optional: remove mesh enrollment from other namespaces; leave Istio/default, ztunnel, and CNI if shared cluster infra
```

---

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)

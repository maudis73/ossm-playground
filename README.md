# OpenShift Service Mesh 3 — Workshop

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

Each phase is a separate `oc apply` moment — capabilities are added gradually (mesh → metrics → tracing backend → tracing enabled).

**Workshop rule:** once a phase is committed, its manifest files are **immutable**. Later capabilities get **new numbered files** only.

## Prerequisites

**Through Phase 5:** cluster admin access, Sail / OSSM operator, Istio CNI operator, **Kiali operator**.

**Phase 6+:** also **Tempo operator**, **OpenTelemetry operator**, and shared **MinIO** in the `minio` namespace (trace storage).

## The application

| Service | Role |
|---------|------|
| **productpage** | Web UI — open in the browser |
| **details** | Backend — **Book Details** table |
| **reviews-v2** | Backend — **Book Reviews** (black star ratings) |
| **ratings** | Backend — called by reviews-v2 for star display |

**productpage** calls **details** and **reviews** on each page load. Traffic path in the mesh: `productpage → details`, `productpage → reviews → ratings`.

Namespace: **`ossm-playground-apps`**

---

## Phase 1 — Deploy apps (outside the mesh)

```bash
oc apply -f manifests/01-apps-namespace.yaml
oc apply -f manifests/02-bookinfo.yaml
oc apply -f manifests/03-route.yaml
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
oc apply -f manifests/04-istio-cni-namespace.yaml
oc apply -f manifests/05-istio-cni-default.yaml
oc wait istiocni/default --for=condition=Ready --timeout=300s
```

**Show:** CNI daemonset Running in `istio-cni`.

**Say:** CNI is required for sidecar injection on OpenShift (no privileged `istio-init` init container).

---

## Phase 3 — Default control plane

Minimal `Istio/default` — discovery selectors only, no tracing or extension providers yet.

```bash
oc apply -f manifests/06-control-plane-namespace.yaml
oc apply -f manifests/07-istio-default.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc get pods -n maurizio-istio-system -l istio=pilot
```

**Show:** `istiod` Healthy. App pods are still **1/1**.

**Say:** only namespaces labeled `istio-discovery=enabled` are in scope for this control plane.

---

## Phase 4 — Enroll the app namespace

```bash
oc apply -f manifests/08-apps-mesh-enroll.yaml
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
oc apply -f manifests/09-istiod-servicemonitor.yaml
oc apply -f manifests/10-podmonitor.yaml
oc apply -f manifests/11-telemetry-metrics.yaml
oc apply -f manifests/12-kiali.yaml
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
oc delete opentelemetrycollector otel -n maurizio-istio-system --ignore-not-found
oc delete tempostack workshop -n tempostack --ignore-not-found
oc apply -f manifests/13-tempostack-namespace.yaml
oc apply -f manifests/14-minio-traces-secret.yaml
oc apply -f manifests/15-tempostack.yaml
oc apply -f manifests/16-otel-collector.yaml
```

Wait until `TempoStack/simplest` is Ready and `OpenTelemetryCollector/otel` is `1/1`.

**Show:** Tempo and collector pods Running; Kiali **Traces** tab still empty.

**Say:** backend is ready; sidecars are not configured to export spans until Phase 7.

---

## Phase 7 — Enable tracing on the mesh

Sidecars send spans **OTLP :4317** → `otel-collector` → Tempo. Kiali **Traces** queries Tempo on **:3200**.

```bash
oc apply -f manifests/17-istio-tracing.yaml
oc apply -f manifests/18-telemetry-tracing.yaml
oc apply -f manifests/19-kiali-tracing.yaml
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

## Manifest index

| File | Purpose |
|------|---------|
| `01-apps-namespace.yaml` | App namespace (no mesh labels) |
| `02-bookinfo.yaml` | productpage, details, reviews-v2, ratings |
| `03-route.yaml` | OpenShift Route to productpage |
| `04-istio-cni-namespace.yaml` | CNI namespace |
| `05-istio-cni-default.yaml` | `IstioCNI/default` |
| `06-control-plane-namespace.yaml` | `maurizio-istio-system` namespace |
| `07-istio-default.yaml` | `Istio/default` — discovery selectors only |
| `08-apps-mesh-enroll.yaml` | Mesh labels on app namespace |
| `09-istiod-servicemonitor.yaml` | Scrape `istiod` metrics (control plane) |
| `10-podmonitor.yaml` | Scrape `istio-proxy` metrics (app workloads) |
| `11-telemetry-metrics.yaml` | `Telemetry/default` — Prometheus metrics only |
| `12-kiali.yaml` | Kiali — graph (Thanos), tracing disabled |
| `13-tempostack-namespace.yaml` | `tempostack` namespace |
| `14-minio-traces-secret.yaml` | S3 secret for Tempo (MinIO backend) |
| `15-tempostack.yaml` | `TempoStack/simplest` |
| `16-otel-collector.yaml` | `OpenTelemetryCollector/otel` → Tempo |
| `17-istio-tracing.yaml` | `Istio/default` — add OTLP extension provider |
| `18-telemetry-tracing.yaml` | `Telemetry/default` — add OTLP tracing |
| `19-kiali-tracing.yaml` | Kiali — enable Tempo tracing |

---

## Cleanup

```bash
oc delete namespace ossm-playground-apps
# Optional: remove mesh enrollment from other namespaces; leave Istio/default and CNI if shared cluster infra
```

---

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)

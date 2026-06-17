# OpenShift Service Mesh 3 — Workshop

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

## Prerequisites

Cluster admin access, Sail / OSSM operator, Istio CNI operator, and **Kiali operator** installed. Tracing (Tempo) is a later module.

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
  -n ossm-playground-apps --timeout=300s
oc get pods -n ossm-playground-apps
```

**Show:** pods are **2/2** (`app` + `istio-proxy`).

**Say:** `istio-discovery=enabled` scopes the namespace to `istiod`; `istio.io/rev=default` enables sidecar injection from `Istio/default`. Existing pods need a restart after labeling.

---

## Phase 5 — Monitoring (Kiali graph, no tracing)

Kiali’s **Graph** uses **Prometheus metrics** from `istio-proxy`. On OpenShift, each meshed app namespace needs a **PodMonitor** so user workload monitoring scrapes sidecar stats.

```bash
oc apply -f manifests/09-podmonitor.yaml
oc apply -f manifests/10-telemetry-metrics.yaml
oc apply -f manifests/11-kiali.yaml
```

Refresh productpage several times, wait ~1 minute, then open Kiali → namespace **ossm-playground-apps** → **Graph**.

```bash
echo "https://$(oc get route kiali -n maurizio-istio-system -o jsonpath='{.spec.host}')"
```

**Show:** edges **productpage → details**, **productpage → reviews → ratings**, request rates on the graph.

**Say:** the mesh works without PodMonitor, but Kiali has no traffic metrics to draw. Tracing is added in a later module.

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
| `07-istio-default.yaml` | `Istio/default` (minimal) |
| `08-apps-mesh-enroll.yaml` | Mesh labels on app namespace |
| `09-podmonitor.yaml` | Scrape `istio-proxy` metrics (OpenShift UWM) |
| `10-telemetry-metrics.yaml` | `Telemetry/default` — Prometheus metrics only |
| `11-kiali.yaml` | Minimal Kiali (Prometheus graph; tracing off) |

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

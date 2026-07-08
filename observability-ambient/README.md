# Observability workshop (ambient) — OpenShift Service Mesh 3

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** in **ambient mode** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

You build mesh observability step by step: **metrics** (Kiali graph), **distributed tracing** (Tempo), and **Envoy access logs** — on an **ambient** dataplane (ztunnel + waypoint). App pods stay **1/1** (no sidecars).

Run `oc apply` commands from the **repository root** (paths below are repo-relative). **Do not edit resources by hand** — each step’s YAML snippet is an excerpt from the manifest file that the `oc apply -f …` command applies.

In Phases 3–8, snippets appear before the apply block so you can see what the command will do:

- **New resource** — what the apply **creates** on the cluster.
- **Update** — what the apply **merges** into an object that already exists (same `kind`, `name`, and namespace). The manifest file in the repo is the full merged result; the snippet shows only the new or changed fields.

### Shared CRs (created once, updated later)

| Resource | Created | Later updates |
|----------|---------|---------------|
| `Istio/default` | Phase 3 | Phase 7 — tracing |
| `Telemetry/default` | Phase 5 — metrics | Phases 7–8 — tracing, access logs |
| `Kiali/kiali-user-workload-monitoring` | Phase 5 | Phase 7 — tracing |
| `Namespace/ossm-playground-ambient-apps` | Phase 1 | Phases 4–4b — ambient + waypoint labels |

## Phases at a glance

| Phase | What you configure | Observability signal |
|-------|-------------------|----------------------|
| 1 | Bookinfo app + Route | — |
| 2 | Istio CNI + ZTunnel (`profile: ambient`) | — |
| 3 | `Istio/default` (ambient, discovery only) | — |
| 4 | Ambient enrollment + waypoint | — |
| 5 | PodMonitor (waypoint), `Telemetry` metrics, Kiali | **Metrics** → Kiali graph |
| 6 | MinIO, TempoStack, OTel collector | Tracing **backend** (no spans yet) |
| 7 | Istio + `Telemetry` + Kiali tracing | **Traces** → Kiali |
| 8 | `Telemetry` access logs | **Access logs** → Kiali waypoint logs |

Phases 1–4 install the ambient mesh incrementally so you can see **which control-plane and Telemetry changes** enable each signal in Phases 5–8.

> **Note — end-state pipeline**
>
> ```
> app pods (1/1)  ──HBONE──►  ztunnel (L4 mTLS)
>        │
>        └──►  waypoint Envoy  ──metrics──►  Prometheus (user workload monitoring)
>                      │
>                      ├──OTLP :4317──►  otel-collector  ──►  TempoStack  ──►  MinIO
>                      │
>                      └──access logs──►  waypoint stdout  ──►  Kiali Logs
>
> Kiali  ──queries──►  Thanos (metrics)  +  Tempo :3200 (traces)
> ```
>
> - **ztunnel** handles L4; **waypoint** provides L7 metrics, traces, and access logs (like a sidecar Envoy).
> - **`Telemetry`** tells the waypoint what to emit; **`PodMonitor`** tells Prometheus what to scrape.
> - The mesh sends traces only after Phase 7; Tempo (Phase 6) is the backend that stores them.

## Prerequisites

Complete these before starting the workshop. The manifests in this repo do not install Operators for you.

> **Fresh cluster:** use a cluster **without** the sidecar [`observability/`](../observability/) workshop already applied. Ambient requires `profile: ambient` on `Istio/default`, `IstioCNI/default`, and `ZTunnel/default` — a sidecar-only control plane must not be reused.

### Log in to OpenShift

You need a user with **cluster-admin** (or equivalent) to install Operators and apply the workshop manifests.

```bash
oc login --token=<token> --server=<api-server>
```

### Install Operators from OperatorHub

Install and ensure these Operators are **Available** (cluster admin task):

- **Red Hat OpenShift Service Mesh 3**
- **Kiali Operator** (provided by Red Hat)
- **Tempo Operator** (provided by Red Hat)
- **Red Hat build of OpenTelemetry**

All are in **OperatorHub** → **Operators** → **Install**.

### Enable user workload monitoring

OpenShift **user workload monitoring** is required for **`PodMonitor`** scraping.

```bash
oc apply -f observability-ambient/manifests/00-user-workload-monitoring.yaml
```

If `cluster-monitoring-config` already exists, ensure `enableUserWorkload` is `true`:

```bash
oc -n openshift-monitoring patch configmap cluster-monitoring-config \
  -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'
```

Verify user workload monitoring is running:

```bash
oc get pods -n openshift-user-workload-monitoring
```

### Clone the workshop repository

```bash
git clone https://github.com/maudis73/ossm-playground.git
cd ossm-playground
```

Run all `oc apply` commands from the **repository root**.

## The application

![Bookinfo architecture (no Istio)](https://istio.io/latest/docs/examples/bookinfo/noistio.svg)

*Source: [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/). This workshop deploys **reviews-v2** (black stars, calls **ratings**).*

| Service | Role |
|---------|------|
| **productpage** | Web UI — open in the browser |
| **details** | Backend — **Book Details** table |
| **reviews-v2** | Backend — **Book Reviews** (black star ratings) |
| **ratings** | Backend — star ratings API (called by reviews) |

**productpage** calls **details** and **reviews** on each page load. Traffic path: `productpage → details`, `productpage → reviews → ratings`.

Namespace: **`ossm-playground-ambient-apps`**

---

## Phase 1 — Deploy apps (outside the mesh)

**Goal:** run Bookinfo with no mesh — baseline before ambient enrollment.

Full manifests: `01`–`03`. No Istio resources yet.

### Apply

```bash
oc apply -f observability-ambient/manifests/01-apps-namespace.yaml
oc apply -f observability-ambient/manifests/02-bookinfo.yaml
oc apply -f observability-ambient/manifests/03-route.yaml
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-ambient-apps --timeout=180s
```

```bash
echo "https://$(oc get route productpage -n ossm-playground-ambient-apps -o jsonpath='{.spec.host}')/productpage"
```

> **Verify:** pods are **1/1**. Open the Route URL — Bookinfo loads.
>
> **Note:** in ambient mode, pods stay **1/1** throughout the workshop — there is no `istio-proxy` sidecar container.

---

## Phase 2 — Istio CNI + ZTunnel

**Goal:** install the CNI plugin and ztunnel for ambient traffic on OpenShift.

Applying `04-istio-cni-namespace.yaml` **creates** the `istio-cni` namespace.

Applying `05-istio-cni-default.yaml` **creates** `IstioCNI/default` with:

```yaml
spec:
  profile: ambient
```

Applying `06-ztunnel-namespace.yaml` **creates** the `ztunnel` namespace.

Applying `07-ztunnel-default.yaml` **creates** `ZTunnel/default` with:

```yaml
spec:
  namespace: ztunnel
  profile: ambient
```

### Apply

```bash
oc apply -f observability-ambient/manifests/04-istio-cni-namespace.yaml
oc apply -f observability-ambient/manifests/05-istio-cni-default.yaml
oc wait istiocni/default --for=condition=Ready --timeout=300s
oc apply -f observability-ambient/manifests/06-ztunnel-namespace.yaml
oc apply -f observability-ambient/manifests/07-ztunnel-default.yaml
oc wait ztunnel/default --for=condition=Ready --timeout=300s
oc get pods -n ztunnel
```

> **Verify:** CNI DaemonSet **Running** in `istio-cni`; ztunnel DaemonSet **Running** in `ztunnel`.
>
> **Note:** ztunnel provides per-node L4 HBONE tunneling and mTLS for ambient workloads.

---

## Phase 3 — Default control plane (ambient)

**Goal:** create `Istio/default` with **ambient profile** and discovery scope only — no observability yet.

Scope the control plane to namespaces labeled `istio-discovery=enabled`.

Applying `08-control-plane-namespace.yaml` **creates** the `istio-system` namespace with:

```yaml
metadata:
  name: istio-system
  labels:
    istio-discovery: enabled
    openshift.io/cluster-monitoring: "true"
```

Applying `09-istio-default.yaml` **creates** `Istio/default` with:

```yaml
spec:
  profile: ambient
  values:
    pilot:
      trustedZtunnelNamespace: ztunnel
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-discovery: enabled
```

### Apply

```bash
oc apply -f observability-ambient/manifests/08-control-plane-namespace.yaml
oc apply -f observability-ambient/manifests/09-istio-default.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc get pods -n istio-system -l istio=pilot
```

> **Verify:** `istiod` is Healthy. App pods are still **1/1** (not in the mesh yet).
>
> **Note:** metrics, tracing, and access logs are added in later phases via `Telemetry` and Kiali — not in this `Istio` CR yet.

---

## Phase 4 — Enroll namespace + waypoint

**Goal:** enroll the app namespace in **ambient mode** and deploy a **waypoint** for L7 telemetry.

L4 (ztunnel) enrollment — applying `10-apps-mesh-enroll.yaml` **updates** the namespace with:

```yaml
metadata:
  name: ossm-playground-ambient-apps
  labels:
    openshift.io/cluster-monitoring: "true"
    istio-discovery: enabled
    istio.io/dataplane-mode: ambient
```

L7 waypoint — applying `11-waypoint-gateway.yaml` **creates** a Gateway:

```yaml
metadata:
  name: waypoint
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

Route traffic through the waypoint — applying `12-apps-use-waypoint.yaml` **updates** the namespace with:

```yaml
metadata:
  labels:
    istio.io/use-waypoint: waypoint
```

### Apply

```bash
oc apply -f observability-ambient/manifests/10-apps-mesh-enroll.yaml
oc apply -f observability-ambient/manifests/11-waypoint-gateway.yaml
oc apply -f observability-ambient/manifests/12-apps-use-waypoint.yaml
oc get pods -n ossm-playground-ambient-apps
oc get gateway waypoint -n ossm-playground-ambient-apps
```

> **Verify:** Bookinfo pods still **1/1**; waypoint pod **Running** (label `gateway.networking.k8s.io/gateway-name=waypoint`). Optional: `istioctl ztunnel-config workloads -n ztunnel` shows enrolled workloads with `PROTOCOL=HBONE`.
>
> **Note:** unlike sidecar enrollment, **no rollout restart** is required for ambient labels. The waypoint provides L7 metrics, tracing, and access logs.

---

## Phase 5 — Monitoring (metrics / Kiali graph)

**Goal:** enable **Prometheus metrics** on the waypoint, **scrape** them, and point **Kiali** at Thanos.

Three resources work together:

**1. `PodMonitor`** — applying `13-podmonitor-waypoint.yaml` **creates**:

```yaml
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: waypoint
  podMetricsEndpoints:
    - path: /stats/prometheus
      interval: 30s
```

**2. `Telemetry/default`** — applying `14-telemetry-metrics.yaml` **creates**:

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: default
  namespace: istio-system
spec:
  metrics:
    - providers:
        - name: prometheus
```

**3. `Kiali`** — applying `15-kiali.yaml` **creates**:

```yaml
spec:
  external_services:
    prometheus:
      thanos_proxy:
        enabled: true
      url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    tracing:
      enabled: false
```

### Apply

```bash
oc apply -f observability-ambient/manifests/13-podmonitor-waypoint.yaml
oc apply -f observability-ambient/manifests/14-telemetry-metrics.yaml
oc apply -f observability-ambient/manifests/15-kiali.yaml
```

Refresh productpage several times, wait ~1 minute, then open Kiali:

```bash
echo "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

Kiali → namespace **ossm-playground-ambient-apps** → **Graph**.

> **Verify:** edges **productpage → details**, **productpage → reviews → ratings**; request rates on the graph. **Traces** tab is still empty.
>
> **Note:** `Telemetry` enables stats on the waypoint Envoy; `PodMonitor` is what makes Prometheus (and Kiali) see them. Both are required for the graph.

---

## Phase 6 — Tracing backend (MinIO + Tempo + OTel collector)

**Goal:** deploy S3-compatible **object storage**, trace **storage** (`TempoStack`), and an **ingestion hop** (`OpenTelemetryCollector`) — the mesh still does not export spans until Phase 7.

**1. MinIO** — applying `observability-ambient/manifests/minio/` **creates** the `minio` namespace, server, and bucket Job.

The bucket name must match `17-minio-traces-secret.yaml`.

Applying `17-minio-traces-secret.yaml` **creates** the S3 secret with:

```yaml
stringData:
  endpoint: http://minio-service.minio.svc.cluster.local:9000
  bucket: ossm-traces
```

**2. `TempoStack`** — applying `18-tempostack.yaml` **creates**:

```yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: simplest
  namespace: tempostack
spec:
  storage:
    secret:
      name: minio-traces-secret
      type: s3
```

**3. `OpenTelemetryCollector`** — applying `19-otel-collector.yaml` **creates**:

```yaml
spec:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: tempo-simplest-distributor.tempostack.svc.cluster.local:4317
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
```

### Apply

```bash
oc apply -f observability-ambient/manifests/minio/
oc get pods,job -n minio
```

Wait until the `minio` pod is **Running** and `create-minio-buckets` is **Completed**, then:

```bash
oc apply -f observability-ambient/manifests/16-tempostack-namespace.yaml
oc apply -f observability-ambient/manifests/17-minio-traces-secret.yaml
oc apply -f observability-ambient/manifests/18-tempostack.yaml
oc apply -f observability-ambient/manifests/19-otel-collector.yaml
```

Wait until `TempoStack/simplest` is Ready and `OpenTelemetryCollector/otel` is `1/1`:

```bash
oc wait tempostack/simplest -n tempostack --for=condition=Ready --timeout=300s
oc get opentelemetrycollector -n istio-system
```

> **Verify:** `minio` pod Running; bucket job **Completed**; Tempo and collector pods Running. Kiali **Traces** tab still empty.
>
> **Note:** this is the **backend pipeline** only. Nothing in the mesh points at the collector yet.

**Troubleshooting** — if Kiali **Traces** later show `connection refused` on `:3200`:

```bash
oc apply -f observability-ambient/manifests/24-tempostack-oauth-proxy-resources.yaml
```

---

## Phase 7 — Enable tracing on the mesh

**Goal:** connect waypoint → collector → Tempo, and enable **Kiali Traces**.

Three resources must agree on the provider name **`otel`**:

**1. `Istio/default`** — applying `20-istio-tracing.yaml` **updates** with:

```yaml
spec:
  values:
    meshConfig:
      enableTracing: true
      extensionProviders:
        - name: otel
          opentelemetry:
            service: otel-collector.istio-system.svc.cluster.local
            port: 4317
```

**2. `Telemetry/default`** — applying `21-telemetry-tracing.yaml` **updates** with:

```yaml
spec:
  tracing:
    - providers:
        - name: otel
      randomSamplingPercentage: 100
```

**3. `Kiali`** — applying `22-kiali-tracing.yaml` **updates** with:

```yaml
spec:
  external_services:
    tracing:
      enabled: true
      provider: tempo
      internal_url: http://tempo-simplest-query-frontend.tempostack.svc.cluster.local:3200
```

### Apply

```bash
oc apply -f observability-ambient/manifests/20-istio-tracing.yaml
oc apply -f observability-ambient/manifests/21-telemetry-tracing.yaml
oc apply -f observability-ambient/manifests/22-kiali-tracing.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc rollout restart deployment -l gateway.networking.k8s.io/gateway-name=waypoint \
  -n ossm-playground-ambient-apps
oc rollout status deployment -l gateway.networking.k8s.io/gateway-name=waypoint \
  -n ossm-playground-ambient-apps --timeout=180s
```

Refresh productpage **10–15 times**, wait ~30s, then Kiali → **ossm-playground-ambient-apps** → **Traces** (range: **Last 1 hour**).

```bash
echo "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

> **Verify:** spans for **productpage → details**, **productpage → reviews → ratings**.
>
> **Note:** flow is **waypoint → otel-collector → Tempo**. Restart the **waypoint** (not Bookinfo apps) after the `Istio` CR change so it picks up `meshConfig`.

---

## Phase 8 — Access logs

**Goal:** add **Envoy access logs** to `Telemetry/default`.

Applying `23-telemetry-accesslogs.yaml` **updates** with:

```yaml
spec:
  accessLogging:
    - providers:
        - name: envoy                 # logs to waypoint Envoy stdout
```

### Apply

```bash
oc apply -f observability-ambient/manifests/23-telemetry-accesslogs.yaml
```

Refresh productpage several times, then Kiali → **Workloads** → **waypoint** → **Logs** → **Proxy logs**. Enable **Spans** to overlay trace markers on the timeline.

> **Verify:** HTTP access lines with response codes and `duration` on the waypoint proxy.
>
> **Note:** in ambient mode, L7 access logs come from the **waypoint** Envoy, not app pods. With tracing enabled, Kiali aligns log lines and spans by time. You now have all three signals: **graph, traces, logs**.

---

## Cleanup

```bash
oc delete namespace ossm-playground-ambient-apps tempostack minio
# Optional: leave Istio/default, CNI, and ztunnel if shared cluster infrastructure
```

---

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)
- [OSSM 3.3 — Ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)

# Observability workshop — OpenShift Service Mesh 3

Hands-on workshop for OSSM 3 on OpenShift using **`Istio/default`** and the [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) sample.

You build mesh observability step by step: **metrics** (Kiali graph), **distributed tracing** (Tempo), and **Envoy access logs** — on a **sidecar** dataplane.

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
| `Namespace/ossm-playground-apps` | Phase 1 | Phase 4 — mesh labels |

## Phases at a glance

| Phase | What you configure | Observability signal |
|-------|-------------------|----------------------|
| 1 | Bookinfo app + Route | — |
| 2 | Istio CNI | — |
| 3 | `Istio/default` (discovery only) | — |
| 4 | Mesh enrollment (sidecar injection) | — |
| 5 | PodMonitor, `Telemetry` metrics, Kiali | **Metrics** → Kiali graph |
| 6 | MinIO, TempoStack, OTel collector | Tracing **backend** (no spans yet) |
| 7 | Istio + `Telemetry` + Kiali tracing | **Traces** → Kiali |
| 8 | `Telemetry` access logs | **Access logs** → Kiali proxy logs |

Phases 1–4 install the mesh incrementally so you can see **which control-plane and Telemetry changes** enable each signal in Phases 5–8.

> **Note — end-state pipeline**
>
> ```
> istio-proxy  ──metrics──►  Prometheus (OpenShift user workload monitoring)
>        │
>        ├──OTLP :4317──►  otel-collector  ──►  TempoStack  ──►  object storage
>        │
>        └──access logs──►  proxy stdout  ──►  Kiali Logs
>
> Kiali  ──queries──►  Thanos (metrics)  +  Tempo :3200 (traces)
> ```
>
> - **`Telemetry`** tells Envoy what to emit; **`PodMonitor`** tells Prometheus what to scrape.
> - The mesh sends traces only after Phase 7; Tempo (Phase 6) is the backend that stores them.

## Prerequisites

Complete these before starting the workshop. The manifests in this repo do not install Operators for you.

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

OpenShift **user workload monitoring** is required for **`PodMonitor`** scraping. If `cluster-monitoring-config` does not exist yet, create it:

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

```bash
oc apply -f observability/manifests/00-user-workload-monitoring.yaml
```

If the ConfigMap already exists, ensure `enableUserWorkload` is `true`:

```bash
oc -n openshift-monitoring patch configmap cluster-monitoring-config \
  -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'
```

Verify user workload monitoring is running:

```bash
oc get pods -n openshift-user-workload-monitoring
```

You should see `prometheus-user-workload` (and related pods) **Running**.

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

Namespace: **`ossm-playground-apps`**

---

## Phase 1 — Deploy apps (outside the mesh)

**Goal:** run Bookinfo with no mesh — baseline before sidecars.

Full manifests: `01`–`03`. No Istio resources yet.

### Apply

```bash
oc apply -f observability/manifests/01-apps-namespace.yaml
oc apply -f observability/manifests/02-bookinfo.yaml
oc apply -f observability/manifests/03-route.yaml
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
```

```bash
echo "https://$(oc get route productpage -n ossm-playground-apps -o jsonpath='{.spec.host}')/productpage"
```

> **Verify:** pods are **1/1** (no sidecar). Open the Route URL — Bookinfo loads.
>
> **Note:** applications run without the mesh; the operator does not inject sidecars by itself.

---

## Phase 2 — Istio CNI

**Goal:** install the CNI plugin so sidecars can redirect traffic on OpenShift.

Full manifests: `04`–`05` (`IstioCNI/default`). Skip if already Healthy.

### Apply

```bash
oc apply -f observability/manifests/04-istio-cni-namespace.yaml
oc apply -f observability/manifests/05-istio-cni-default.yaml
oc wait istiocni/default --for=condition=Ready --timeout=300s
```

> **Verify:** CNI DaemonSet Running in `istio-cni`.
>
> **Note:** on OpenShift, the CNI plugin redirects pod traffic — no privileged `istio-init` init container.

---

## Phase 3 — Default control plane

**Goal:** create `Istio/default` with **discovery scope only** — no observability yet.

Scope the control plane to namespaces labeled `istio-discovery=enabled`.

Applying `06-control-plane-namespace.yaml` **creates** the `istio-system` namespace with:

```yaml
metadata:
  name: istio-system
  labels:
    istio-discovery: enabled
    openshift.io/cluster-monitoring: "true"
```

Applying `07-istio-default.yaml` **creates** `Istio/default` with:

```yaml
spec:
  values:
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-discovery: enabled
```

### Apply

```bash
oc apply -f observability/manifests/06-control-plane-namespace.yaml
oc apply -f observability/manifests/07-istio-default.yaml
oc wait istio/default --for=condition=Ready --timeout=300s
oc get pods -n istio-system -l istio=pilot
```

> **Verify:** `istiod` is Healthy. App pods are still **1/1** (not in the mesh yet).
>
> **Note:** metrics, tracing, and access logs are added in later phases via `Telemetry` and Kiali — not in this `Istio` CR yet.

---

## Phase 4 — Enroll the app namespace

**Goal:** label the app namespace so **sidecars are injected** from `Istio/default`.

Add mesh labels to `ossm-playground-apps`.

Applying `08-apps-mesh-enroll.yaml` **updates** the namespace with:

```yaml
metadata:
  name: ossm-playground-apps
  labels:
    openshift.io/cluster-monitoring: "true"
    istio-discovery: enabled
    istio.io/rev: default
```

### Apply

```bash
oc apply -f observability/manifests/08-apps-mesh-enroll.yaml
oc rollout restart deployment -n ossm-playground-apps
oc rollout status deployment/details-v1 deployment/reviews-v2 deployment/ratings-v1 deployment/productpage-v1 \
  -n ossm-playground-apps --timeout=180s
oc get pods -n ossm-playground-apps
```

> **Verify:** pods are **2/2** (`app` + `istio-proxy`).
>
> **Note:** existing pods need a restart after labeling — injection applies on pod create.

---

## Phase 5 — Monitoring (metrics / Kiali graph)

**Goal:** enable **Prometheus metrics** on proxies, **scrape** them, and point **Kiali** at Thanos.

Three resources work together:

**1. `PodMonitor`** — applying `10-podmonitor.yaml` **creates**:

```yaml
spec:
  podMetricsEndpoints:
    - path: /stats/prometheus
      interval: 30s
  selector:
    matchExpressions:
      - key: istio-prometheus-ignore
        operator: DoesNotExist
```

**2. `Telemetry/default`** — applying `11-telemetry-metrics.yaml` **creates**:

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: default
  namespace: istio-system          # mesh-wide default
spec:
  metrics:
    - providers:
        - name: prometheus           # built-in Envoy stats provider
```

**3. `Kiali`** — applying `12-kiali.yaml` **creates**:

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
oc apply -f observability/manifests/10-podmonitor.yaml
oc apply -f observability/manifests/11-telemetry-metrics.yaml
oc apply -f observability/manifests/12-kiali.yaml
```

Refresh productpage several times, wait ~1 minute, then open Kiali:

```bash
echo "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

Kiali → namespace **ossm-playground-apps** → **Graph**.

> **Verify:** edges **productpage → details**, **productpage → reviews → ratings**; request rates on the graph. **Traces** tab is still empty.
>
> **Note:** `Telemetry` enables stats on proxies; `PodMonitor` is what makes Prometheus (and Kiali) see them. Both are required for the graph.

---

## Phase 6 — Tracing backend (MinIO + Tempo + OTel collector)

**Goal:** deploy S3-compatible **object storage**, trace **storage** (`TempoStack`), and an **ingestion hop** (`OpenTelemetryCollector`) — proxies still do not export spans until Phase 7.

**1. MinIO — S3 object storage for traces**

Applying `observability/manifests/minio/` **creates** the `minio` namespace, server, service, and a Job that creates the `ossm-traces` bucket once MinIO is up.

The bucket name must match `14-minio-traces-secret.yaml`.

Applying `14-minio-traces-secret.yaml` **creates** the S3 secret with:

```yaml
stringData:
  endpoint: http://minio-service.minio.svc.cluster.local:9000
  bucket: ossm-traces
```

**2. `TempoStack`** — applying `15-tempostack.yaml` **creates**:

```yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: simplest
  namespace: tempostack
spec:
  storage:
    secret:
      name: minio-traces-secret    # S3 endpoint + bucket (manifest 14)
      type: s3
```

**3. `OpenTelemetryCollector`** — applying `16-otel-collector.yaml` **creates**:

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

Apply MinIO first, wait for the bucket Job, then deploy Tempo and the collector:

```bash
oc apply -f observability/manifests/minio/
oc get pods,job -n minio
```

Wait until the `minio` pod is **Running** and `create-minio-buckets` is **Completed**, then:

```bash
oc apply -f observability/manifests/13-tempostack-namespace.yaml
oc apply -f observability/manifests/14-minio-traces-secret.yaml
oc apply -f observability/manifests/15-tempostack.yaml
oc apply -f observability/manifests/16-otel-collector.yaml
```

Wait until `TempoStack/simplest` is Ready and `OpenTelemetryCollector/otel` is `1/1`.

> **Verify:** `minio` pod Running; bucket job **Completed**; Tempo and collector pods Running. Kiali **Traces** tab still empty.
>
> **Note:** this is the **backend pipeline** only. Nothing in the mesh points at the collector yet.

**Troubleshooting** — if Kiali **Traces** later show `connection refused` on `:3200`:

```bash
oc apply -f observability/manifests/21-tempostack-oauth-proxy-resources.yaml
```

---

## Phase 7 — Enable tracing on the mesh

**Goal:** connect sidecars → collector → Tempo, and enable **Kiali Traces**.

Three resources must agree on the provider name **`otel`**:

**1. `Istio/default`** — applying `17-istio-tracing.yaml` **updates** with:

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

**2. `Telemetry/default`** — applying `18-telemetry-tracing.yaml` **updates** with:

```yaml
spec:
  tracing:
    - providers:
        - name: otel                    # must match extensionProviders name
      randomSamplingPercentage: 100
```

**3. `Kiali`** — applying `19-kiali-tracing.yaml` **updates** with:

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
echo "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

> **Verify:** spans for **productpage → details**, **productpage → reviews → ratings**.
>
> **Note:** flow is **sidecar → otel-collector → Tempo**. Proxies need a restart after the `Istio` CR change so they pick up `meshConfig`.

---

## Phase 8 — Access logs

**Goal:** add **Envoy access logs** to `Telemetry/default`.

Applying `20-telemetry-accesslogs.yaml` **updates** with:

```yaml
spec:
  accessLogging:
    - providers:
        - name: envoy                 # logs to istio-proxy stdout
```

### Apply

```bash
oc apply -f observability/manifests/20-telemetry-accesslogs.yaml
```

Refresh productpage several times, then Kiali → **Workloads** → **productpage-v1** → **Logs** → **Proxy logs**. Enable **Spans** to overlay trace markers on the timeline.

> **Verify:** HTTP access lines (`GET /productpage`, `GET /details`, …) with response codes and `duration`.
>
> **Note:** access logs are per-hop `istio-proxy` output. With tracing enabled, Kiali aligns log lines and spans by time. You now have all three signals: **graph, traces, logs**.

---

## Cleanup

```bash
oc delete namespace ossm-playground-apps tempostack minio
# Optional: leave Istio/default and CNI if shared cluster infrastructure
```

---

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)

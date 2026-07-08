# OpenShift Service Mesh 3 — Playground

Hands-on workshops for [OpenShift Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3) on OpenShift.

Repository: [github.com/maudis73/ossm-playground](https://github.com/maudis73/ossm-playground)

## Demos

| Demo | Status | Description |
|------|--------|-------------|
| **[observability](observability/README.md)** | Active | Bookinfo on **sidecars** — metrics, tracing (Tempo), access logs (8 phases) |
| **[observability-ambient](observability-ambient/README.md)** | Active | Bookinfo on **ambient** (ztunnel + waypoint) — same three signals (8 phases) |
| **[garanti-labs](garanti-labs/README.md)** | Active | Garanti Q3–Q12 hands-on labs (gRPC, metrics, latency, non-mesh, retry, gateway, logging, VS/DR lifecycle) |
| **[ambient](ambient/README.md)** | Planned | Mixed-mode traffic — sidecar and ambient workloads coexist |
| **[security](security/README.md)** | Planned | Policy, mTLS, authorization |

## Shared prerequisites

See **[observability/README.md](observability/README.md#prerequisites)** for the full list: Operators (OSSM 3, Kiali, Tempo, OpenTelemetry), user workload monitoring, and cluster admin access.

The **ambient** workshop requires a **fresh cluster** (do not reuse a sidecar-only `Istio/default` from the sidecar observability lab).

## Getting started

```bash
git clone https://github.com/maudis73/ossm-playground.git
cd ossm-playground
# Sidecar workshop:
less observability/README.md
# Ambient workshop (fresh cluster):
less observability-ambient/README.md
# Garanti customer labs (single linear guide):
less garanti-labs/README.md
```

## Cleanup

Each demo documents its own namespaces. Sidecar observability removes `ossm-playground-apps`, `tempostack`, and `minio`. Ambient observability removes `ossm-playground-ambient-apps`, `tempostack`, and `minio`. Shared control plane (`Istio/default`, CNI, ztunnel) can stay on lab clusters.

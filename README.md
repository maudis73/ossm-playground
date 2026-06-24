# OpenShift Service Mesh 3 — Playground

Hands-on workshops for [OpenShift Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3) on OpenShift.

Repository: [github.com/maudis73/ossm-playground](https://github.com/maudis73/ossm-playground)

## Demos

| Demo | Status | Description |
|------|--------|-------------|
| **[observability](observability/README.md)** | Active | Bookinfo on sidecars — metrics, tracing (Tempo), access logs (8 phases) |
| **[ambient](ambient/README.md)** | Planned | Ambient dataplane — ztunnel, waypoints, cross-mode traffic |
| **[security](security/README.md)** | Planned | Policy, mTLS, authorization |

## Shared prerequisites

See **[observability/README.md](observability/README.md#prerequisites)** for the full list: Operators (OSSM 3, Kiali, Tempo, OpenTelemetry), user workload monitoring, and cluster admin access.

## Getting started

```bash
git clone https://github.com/maudis73/ossm-playground.git
cd ossm-playground
# Follow phases in order:
less observability/README.md
```

## Cleanup

Each demo documents its own namespaces. Observability removes `ossm-playground-apps`, `tempostack`, and `minio`; shared control plane (`Istio/default`, CNI) can stay on lab clusters.

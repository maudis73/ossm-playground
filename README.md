# OpenShift Service Mesh 3 — Playground

Hands-on workshops for [OpenShift Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3) on OpenShift.

Repository: [github.com/maudis73/ossm-playground](https://github.com/maudis73/ossm-playground)

## Demos

| Demo | Status | Description |
|------|--------|-------------|
| **[observability](observability/README.md)** | Active | Bookinfo — mesh metrics, tracing (Tempo), access logs, ambient ratings (Phase 9) |
| **[ambient](ambient/README.md)** | Planned | Ambient mesh deep-dive |
| **[security](security/README.md)** | Planned | Policy, mTLS, authorization |

## Shared prerequisites

- Cluster admin access (some phases)
- Sail / OSSM operator, Istio CNI operator, **Kiali operator**
- OpenShift **user workload monitoring** enabled (for Prometheus / Kiali graph)
- For observability Phases 6+: **Tempo operator**, **OpenTelemetry operator**, shared **MinIO** in `minio` (trace storage)

## Getting started

Start with the observability workshop:

```bash
# Clone, then follow phases in order:
cat observability/README.md
```

## Cleanup

Each demo documents its own namespaces. Observability removes `ossm-playground-apps` and `ossm-playground-ambient`; shared control plane (`Istio/default`, CNI, ztunnel) can stay on lab clusters.

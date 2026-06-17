# OpenShift Service Mesh 3 — Workshop

Hands-on workshop for OpenShift Service Mesh (OSSM) 3 on OpenShift.

## Prerequisites

Operators and cluster tooling are assumed to be installed already (documented separately). This repo only contains the workshop steps.

## Workshop phases

| Phase | Directory | What you do |
|-------|-----------|-------------|
| **010** | `010-control-plane/` | Install a dedicated mesh control plane with discovery selectors |
| **020** | `020-bookinfo/` | Deploy Bookinfo (outside the mesh) |
| **030** | `030-sidecar-enroll/` | Enroll the app namespace (sidecar proxies) |

Later modules (observability, ambient mode, traffic management) will be added in follow-on branches.

## Design notes

- **Control plane first**, then apps — mesh infrastructure before Bookinfo.
- **Sidecar path first**; ambient mode (Ztunnel, waypoints) in a later module.
- **Discovery selectors** limit which namespaces the control plane manages (`istio-discovery` label).

## Cleanup

See `cleanup/README.md` when added.

## References

- [Istio Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)
- [Red Hat OpenShift Service Mesh 3.3 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3)

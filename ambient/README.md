# Ambient mesh workshop (planned)

This module will cover the **ambient dataplane**: ztunnel, waypoints, namespace enrollment, and observability when sidecar and ambient workloads coexist.

Topics to include:

- Enabling `profile: ambient` on the control plane and CNI
- Moving a workload (e.g. Bookinfo **ratings**) to an ambient namespace
- Waypoint proxies for L7 policy and telemetry
- Cross-mode traffic (sidecar client → ambient destination)

**Status:** not yet implemented. Complete the **[observability](../observability/README.md)** workshop first (sidecar metrics, traces, and access logs).

# Access to non-mesh services and webhook pods

**Audience:** Garanti BBVA platform / mesh team  
**Status:** Draft for review — intended for `Garanti-OSSM-Responses.md`  
**Related lab:** `nonmesh-access/` (this project)

---

## Questions

- What happens when a meshed pod tries to access a non-mesh internal service?
- When is traffic blocked (mTLS, missing ServiceEntry, outbound policies)?
- How should we configure access for **Kubernetes admission webhooks**, internal services without sidecars, and other cluster endpoints?
- Are ServiceEntry or Sidecar resources required?

---

## Answer

Treat this as **two paths**:

| Path | Client | What “in the mesh” means |
|------|--------|---------------------------|
| **A. Meshed → non-mesh Service** | App + `istio-proxy` | Outbound policy (mTLS, ServiceEntry, Sidecar egress) |
| **B. Admission webhook** | **API server** | Whether the **webhook pod** has a sidecar on the **inbound** path |

---

### 1. Meshed pod → non-mesh internal service

Outbound from a meshed pod goes through **`istio-proxy`**. Destination may be another meshed pod, a **plain** Service (no sidecar), or something outside the cluster.

For a **Kubernetes Service in a non-injected namespace** (same cluster):

| Mesh setting | Typical behavior |
|--------------|------------------|
| **mTLS PERMISSIVE** (common default) | Client Envoy often reaches the plain Service over **plaintext**. Call **succeeds** without a ServiceEntry for basic connectivity. |
| **mTLS STRICT** | Client may **expect mTLS**. Plain cleartext backends **fail** unless you carve out an exception (`DestinationRule` `tls.mode: DISABLE`, or keep that path off STRICT). |
| **Sidecar egress allow-list** | Omitting the destination namespace/host **blocks** the call until you add it. |
| **`outboundTrafficPolicy: REGISTRY_ONLY`** | Only hosts in the mesh registry (known Services + **ServiceEntry**) are allowed. |

**Takeaway:** Behavior depends on **mTLS mode**, **egress policy**, and whether the host is in the **Istio registry** — not on “Istio blocks all non-mesh by default.”

---

### 2. When that traffic is blocked

| Cause | What you see | Fix |
|-------|----------------|-----|
| **STRICT mTLS** to a plaintext-only pod | Connection / TLS errors | `DestinationRule` TLS `DISABLE` for that host; or inject/mesh the backend |
| **Missing ServiceEntry** under `REGISTRY_ONLY` | Outbound refused / blackhole | Add `ServiceEntry` (+ often `DestinationRule`) |
| **Sidecar egress** too tight | Timeouts / 502 / no route | Add destination to Sidecar `egress.hosts` (e.g. `"plain-ns/*"`) |
| **NetworkPolicy** / OpenShift SDN | Independent of Istio | Allow client NS → server NS |
| **Wrong port / protocol** | Protocol errors | Align Service port name / `appProtocol` |

**ServiceEntry** registers a host so Istio can apply L7 routing, TLS mode, and egress allow-lists. It does not by itself replace mTLS policy.

---

### 3. Kubernetes admission webhooks (pods that *run* webhooks)

Admission is **triggered by the API server**, not by Istio:

```text
API request → API server matches Validating/MutatingWebhookConfiguration
  → HTTPS to your webhook Service
  → webhook pod responds allow/deny
```

Putting webhook pods “in the mesh” does **not** change *who* calls them. It only adds a possible **sidecar on the inbound path** from the API server.

| Concern | Guidance |
|---------|----------|
| How is it triggered if the webhook sits in the mesh? | **Same as outside:** API server → Service → pod |
| What breaks when injected? | Envoy inbound intercept / mTLS expectations can cause `failed calling webhook` / timeouts |
| ServiceEntry / Sidecar egress? | **Not** the levers for this path (API server is not a meshed client) |
| Recommended config | Prefer **non-injected** webhook Deployments/namespaces |
| If you must inject | `traffic.sidecar.istio.io/excludeInboundPorts: "<listen-port>"` so API server TLS reaches the app; still validate readiness and NetworkPolicy |

App HTTP “callback” URLs (meshed service POSTs to a plain URL) are **not** admission — treat them like §1 (meshed → plain).

#### Other cluster endpoints

- **Kubernetes API / DNS:** usually covered by default mesh exceptions; do not lock Sidecar egress so tightly that you break DNS or istiod.  
- **External URLs:** `ServiceEntry` (`MESH_EXTERNAL`) + optional egress gateway.  
- **Sidecar CR:** always leave the control-plane namespace (e.g. `maurizio-istio-system/*`) on the egress allow-list.

---

### 4. Are ServiceEntry or Sidecar required?

| Resource | Meshed → plain | Admission (API server → webhook) |
|----------|----------------|-----------------------------------|
| **ServiceEntry** | Not always (PERMISSIVE + allow-any); yes for `REGISTRY_ONLY` / L7/DR needs | **No** |
| **Sidecar (egress)** | Not required to “enable” access; required to **allow** a host once you tighten egress | **No** |
| **Injection off / excludeInboundPorts** | N/A | **Yes** — this is the relevant control |

**Practical pattern for Garanti (~3,200 services):**

1. Keep **Sidecar egress** generated from known outbound dependencies.  
2. Enumerate known **plain / platform** namespaces on that allow list; use **ServiceEntry** where registry/TLS policy needs it.  
3. Run **admission webhook** controllers **non-injected** (or validated `excludeInboundPorts`).  
4. Treat **STRICT mTLS** as a separate rollout: inventory plain backends first.

---

### 5. Recommendations (summary)

| Scenario | Recommendation |
|----------|----------------|
| Meshed → plain (PERMISSIVE) | Often works; add ServiceEntry + Sidecar allow when you tighten egress |
| Meshed → plain under STRICT | Plan TLS `DISABLE` DR or inject the backend |
| Admission webhooks | Prefer non-mesh webhook pods; validate API server → Service path |
| App HTTP callbacks | Same as meshed → plain |

---

## Lab reference

| Part | Namespaces | Phases |
|------|------------|--------|
| Meshed → plain | `nonmesh-lab` / `nonmesh-plain` | A–D |
| Admission in/out of mesh | `admission-lab` / `admission-test` | F–H |

See [README.md](README.md).

---

## Revision

| Date | Change |
|------|--------|
| 2026-07-24 | Clarified admission (API server → webhook); lab covers both egress and admission; removed fake app “webhook-simulator” |
| 2026-07-23 | Initial draft (non-mesh access + webhooks) |

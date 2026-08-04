# Access to non-mesh services and admission webhooks — lab guide

Two related mesh-boundary topics in one lab:

1. **Meshed → plain** — a pod with `istio-proxy` calling a Service whose pods have **no** sidecar.  
2. **Admission webhooks** — the **API server** calling a webhook Service; what changes if that webhook pod **is** injected.

These are **different traffic directions**. Part 1 is about **outbound** from a meshed app. Part 2 is about **inbound** to a webhook that the control plane calls. Mixing them up is the most common misunderstanding in this topic.

| Artifact | Purpose |
|----------|---------|
| **This README** | Step-by-step lab guide (copy-paste `oc` commands) |
| [k8s/](k8s/) | Manifests |

Enter the lab directory so relative `k8s/…` paths work:

```bash
cd ossm-playground/nonmesh-access
```

---

## Concepts

### Meshed vs plain

| | Meshed | Plain |
|--|--------|-------|
| Ready | often **2/2** (`app` + `istio-proxy`) | **1/1** (app only) |
| Outbound | through Envoy | normal pod networking |
| This lab | `nonmesh-lab` / `mesh-client` | `nonmesh-plain` / `httpbin` |

Namespace labels that enable injection here: `istio.io/rev=default`, `istio-discovery=enabled`.

When you see **Ready 2/2**, that means two containers share one pod network namespace: your app (`curl`) and the mesh proxy (`istio-proxy`). You run `curl` **inside** the app container (`-c curl`); the datapath still leaves as **app → istio-proxy → network**.

### Sidecar **container** vs `Sidecar` **CR**

| Term | Meaning |
|------|---------|
| `istio-proxy` | Envoy container injected into the pod |
| `Sidecar` CR | Optional Kubernetes resource that **limits egress** configured for that proxy |

Phases C/D apply a **`Sidecar` CR**. That does **not** add a second proxy — it changes the config istiod pushes to the existing `istio-proxy`.

### ServiceEntry

Registers a hostname with Istio so the mesh can apply L7 rules, TLS mode, or registry-only egress. Same-cluster Services already resolve via DNS; ServiceEntry is about **mesh policy**, not inventing DNS.

### mTLS PERMISSIVE vs STRICT (short)

| Mode | Meshed client → plain HTTP server |
|------|-----------------------------------|
| **PERMISSIVE** (typical default) | Client proxy can use plaintext; call often **works** |
| **STRICT** | Client may expect mutual TLS; plain cleartext servers **fail** unless you add exceptions |

This lab stays on **PERMISSIVE**. Do not enable STRICT on a shared cluster for this exercise.

### Admission webhook (different path)

```text
oc apply / kubectl
  → API server
  → HTTPS to ValidatingWebhookConfiguration Service
  → webhook pod
```

Istio does **not** trigger admission. A sidecar on the webhook only risks **breaking inbound** API-server HTTPS.

---

## Architecture

**Part 1 — egress to non-mesh**

```text
nonmesh-lab (injected)              nonmesh-plain (NOT injected)
┌─────────────────────────┐         ┌──────────────────────────┐
│ mesh-client             │  HTTP   │ httpbin (go-httpbin)     │
│  curl + istio-proxy     │ ──────► │  :8080 (Service :80)     │
└─────────────────────────┘         └──────────────────────────┘
```

**Part 2 — admission**

```text
API server ──HTTPS──► admission-webhook.admission-lab ──► webhook pod :8443
                         (Phase F: no sidecar)
                         (Phase G: + sidecar — often breaks)
                         (Phase H: excludeInboundPorts — works again)
```

---

## Prerequisites

You need `oc`, OSSM with Istio revision **`default`**, rights to create namespaces / Deployments / ServiceEntry / Sidecar / `ValidatingWebhookConfiguration`, plus `openssl` and `base64`.

The Sidecar manifests allow **`maurizio-istio-system/*`** (where istiod runs). Edit `k8s/04-sidecar-deny-plain.yaml` and `k8s/05-sidecar-allow-plain.yaml` if yours differs. If you omit istiod from the allow-list, proxies can stop receiving config updates.

Check that the mesh control plane exists and istiod is running:

```bash
oc get istio -A
oc get pods -n maurizio-istio-system -l app=istiod
```

---

# Part 1 — Meshed → plain Service

**What this part demonstrates:** Platforms still run Services without sidecars. Meshed apps must call them. We prove that (under PERMISSIVE) the call often works with no extra CRs, then show how **ServiceEntry** and a tight **Sidecar egress** list change the picture.

---

## Phase 0 — Clean slate (egress namespaces)

Confirm which user and cluster you are on:

```bash
oc whoami
```

Check that the `default` Istio control plane is healthy (expect something like `Healthy` and revision `default`):

```bash
oc get istio default -o jsonpath='{.status.state} rev={.status.activeRevisionName}{"\n"}'
```

Remove leftover namespaces from a previous run so old Sidecar/ServiceEntry objects cannot skew results:

```bash
oc delete namespace nonmesh-lab nonmesh-plain --wait=false --ignore-not-found
```

---

## Phase 1 — Deploy meshed client + plain httpbin

Create two namespaces on purpose:

- **`nonmesh-lab`** — `istio-discovery=enabled` **and** `istio.io/rev=default` → client gets a proxy (**2/2**; on this cluster `istio-proxy` may appear as a native sidecar / init container).
- **`nonmesh-plain`** — `istio-discovery=enabled` but **no** `istio.io/rev` → Services are visible to Istio for Sidecar egress, but pods stay **uninjected** (**1/1**).

```bash
oc apply -f k8s/00-namespaces.yaml
oc get ns nonmesh-lab nonmesh-plain --show-labels
```

Deploy the meshed curl client into `nonmesh-lab`:

```bash
oc apply -f k8s/01-client.yaml
```

Deploy plain httpbin into `nonmesh-plain`. It listens on **8080** inside the container (OpenShift non-root cannot bind port 80); the Service still exposes port **80** and forwards to 8080:

```bash
oc apply -f k8s/02-httpbin.yaml
```

Wait until both Deployments are rolled out:

```bash
oc rollout status deployment/mesh-client -n nonmesh-lab --timeout=180s
oc rollout status deployment/httpbin -n nonmesh-plain --timeout=180s
```

List the pods. Expect `mesh-client` **2/2** and `httpbin` **1/1**:

```bash
oc get pods -n nonmesh-lab -o wide
oc get pods -n nonmesh-plain -o wide
```

List containers on the client so you can see `curl` (app) and `istio-proxy` (mesh) separately:

```bash
oc get pod -n nonmesh-lab -l app=mesh-client \
  -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}{" ready="}{.ready}{"\n"}{end}'
```

**Expect:**

```text
curl ready=true
istio-proxy ready=true
```

If `mesh-client` is only **1/1**, injection failed — later phases will not behave as documented. Re-check namespace labels and that `Istio/default` is Healthy.

Confirm no ServiceEntry or Sidecar CR exists yet. Phase A must be a “defaults only” baseline:

```bash
oc get serviceentry,sidecar -n nonmesh-lab
```

**Expect:** `No resources found`.

---

## Phase A — Call plain httpbin with no extra CRs

**Question:** Can a meshed pod reach a plain Service using only cluster DNS, with no ServiceEntry and no Sidecar CR?

**Why it usually works:** With **PERMISSIVE** mTLS, the client `istio-proxy` may speak plaintext to a server that has no sidecar. The destination does not need to be injected for basic HTTP.

From inside the **app** container (`-c curl`), call httpbin. Traffic still leaves the pod through `istio-proxy`:

```bash
oc exec -n nonmesh-lab deploy/mesh-client -c curl -- \
  curl -sS -o /dev/null -w 'httpbin HTTP %{http_code}\n' --max-time 15 \
  http://httpbin.nonmesh-plain.svc.cluster.local/get
```

**Expect:** `httpbin HTTP 200`

**Takeaway:** “Outside the mesh” does **not** mean “blocked by default” on a typical PERMISSIVE setup. Blockage usually comes from policy you add later (or STRICT mTLS), not from the mere absence of a sidecar on the server.

---

## Phase B — ServiceEntry

**Question:** What does adding a ServiceEntry change when Phase A already returned 200?

**Answer:** It registers the hostname with Istio so policy and L7 features can target it. It is **not** always required just to get HTTP success on same-cluster Services. We still apply it so you see the object and understand when teams *do* need it (`REGISTRY_ONLY`, DestinationRule TLS, clearer allow-lists).

Register the plain httpbin hostname in the Istio registry:

```bash
oc apply -f k8s/03-serviceentry.yaml
```

Show that the ServiceEntry exists:

```bash
oc get serviceentry -n nonmesh-lab
```

Give istiod a few seconds to push config to the proxy:

```bash
sleep 5
```

Retest the same call — you should still get 200 (ServiceEntry did not “enable” something that was broken):

```bash
oc exec -n nonmesh-lab deploy/mesh-client -c curl -- \
  curl -sS -o /dev/null -w 'httpbin HTTP %{http_code}\n' --max-time 15 \
  http://httpbin.nonmesh-plain.svc.cluster.local/get
```

**Expect:** still `200`.

**Takeaway:** ServiceEntry is often **optional** for same-cluster PERMISSIVE calls; it becomes important when outbound policy is locked to the Istio registry or when you need L7/TLS settings for that host.

---

## Phase C — Sidecar CR blocks plain namespace

**Question:** If we tighten what `istio-proxy` is allowed to dial, can we block plain backends even though Phase A worked?

`k8s/04-sidecar-deny-plain.yaml` is a **`Sidecar` API object** (not a new container). Important details for your cluster:

- **`outboundTrafficPolicy: REGISTRY_ONLY`** — required so omitted hosts are not reached via the ALLOW_ANY passthrough cluster.
- Egress hosts only: `./*` (this namespace) and `maurizio-istio-system/*` (istiod). **No** `nonmesh-plain/*`.
- Delete the Phase B ServiceEntry first: it lives in `nonmesh-lab`, so `./*` would still allow that host and hide the Sidecar effect.

Remove the ServiceEntry, then apply the tight Sidecar. Use **`oc replace`** (or delete + apply) when updating an existing Sidecar so the hosts list is fully replaced:

```bash
oc delete serviceentry httpbin-plain -n nonmesh-lab --ignore-not-found
oc apply -f k8s/04-sidecar-deny-plain.yaml
# If the Sidecar already exists from a prior run:
# oc replace -f k8s/04-sidecar-deny-plain.yaml
```

Inspect the egress hosts list (should **not** include `nonmesh-plain/*`):

```bash
oc get sidecar mesh-client-egress -n nonmesh-lab -o jsonpath='{.spec.egress[0].hosts}{"\n"}'
oc get sidecar mesh-client-egress -n nonmesh-lab -o jsonpath='{.spec.outboundTrafficPolicy.mode}{"\n"}'
```

Wait for config push to the proxy:

```bash
sleep 15
```

Call httpbin again. Expect failure (connection reset, HTTP 000, timeout, or the `FAILED` line):

```bash
oc exec -n nonmesh-lab deploy/mesh-client -c curl -- \
  curl -sS -o /dev/null -w 'httpbin HTTP %{http_code}\n' --connect-timeout 5 --max-time 15 \
  http://httpbin.nonmesh-plain.svc.cluster.local/get || echo 'httpbin FAILED (expected)'
```

If it still returns 200, wait longer, confirm `REGISTRY_ONLY`, and confirm hosts lack `nonmesh-plain/*`.

**Takeaway:** A **`Sidecar` CR** egress list is an **outbound allow-list**. With **`REGISTRY_ONLY`**, destinations not on that list (and not otherwise in the configured registry view) are blocked — even if DNS still resolves.

---

## Phase D — Sidecar CR allows `nonmesh-plain/*`

**Question:** After explicitly allowing the plain namespace, does traffic work again?

We keep **`REGISTRY_ONLY`** but add `nonmesh-plain/*` to egress hosts. Because `nonmesh-plain` is labeled `istio-discovery=enabled`, istiod knows the httpbin Service and can program the proxy for it — without needing the ServiceEntry from Phase B.

Use **`oc replace`** so the hosts list updates cleanly:

```bash
oc replace -f k8s/05-sidecar-allow-plain.yaml
```

Confirm hosts now include `nonmesh-plain/*`:

```bash
oc get sidecar mesh-client-egress -n nonmesh-lab -o jsonpath='{.spec.egress[0].hosts}{"\n"}'
```

Wait for config push:

```bash
sleep 15
```

Call httpbin again — expect 200:

```bash
oc exec -n nonmesh-lab deploy/mesh-client -c curl -- \
  curl -sS -o /dev/null -w 'httpbin HTTP %{http_code}\n' --max-time 15 \
  http://httpbin.nonmesh-plain.svc.cluster.local/get
```

**Expect:** `httpbin HTTP 200`

**Takeaway:** Once Sidecar egress is locked down with **`REGISTRY_ONLY`**, DNS alone is not enough — the destination namespace/host must be on the allow list **and** visible to istiod (discovery label and/or ServiceEntry).

**Part 1 complete.** You can leave these namespaces running for Part 2, or clean them later.

---

# Part 2 — Admission webhook pods and the mesh

**What this part demonstrates:** Teams ask how admission still “works in the mesh.” Admission is always API server → webhook. We show a working webhook **without** a sidecar, then inject one and watch creates fail, then recover with `excludeInboundPorts`. Recommended production pattern: **do not inject** admission controllers.

---

## Phase E — Admission namespaces + TLS

Create `admission-lab` (hosts the webhook, starts non-injected) and `admission-test` (labeled so **only** Pod CREATEs here hit our webhook — limits blast radius):

```bash
oc apply -f k8s/09-admission-namespaces.yaml
```

Confirm labels: `admission-lab` has **no** `istio.io/rev`; `admission-test` has `admission-lab=true`:

```bash
oc get ns admission-lab admission-test --show-labels
```

Kubernetes admission webhooks must use **HTTPS**. Create a working directory for a self-signed cert whose SAN matches the webhook Service DNS name:

```bash
mkdir -p /tmp/admission-lab-certs
cd /tmp/admission-lab-certs
```

Generate the certificate and private key (this is a Kubernetes requirement, not an Istio one):

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout tls.key -out tls.crt -days 365 \
  -subj "/CN=admission-webhook.admission-lab.svc" \
  -addext "subjectAltName=DNS:admission-webhook.admission-lab.svc,DNS:admission-webhook.admission-lab.svc.cluster.local"
```

Store the cert/key as a Secret so the webhook pod can mount them and serve TLS:

```bash
oc create secret tls admission-webhook-certs \
  -n admission-lab \
  --cert=tls.crt \
  --key=tls.key \
  --dry-run=client -o yaml | oc apply -f -
```

Base64-encode the certificate. You will paste this into the ValidatingWebhookConfiguration as `caBundle` so the API server trusts the webhook:

```bash
CA_BUNDLE=$(base64 -w0 tls.crt)
echo "CA_BUNDLE length: ${#CA_BUNDLE}"
```

Return to the lab directory for later `oc apply -f k8s/…` commands:

```bash
cd ossm-playground/nonmesh-access
```

**Why `caBundle` matters:** Without it (or with the wrong CA), the API server refuses to trust the webhook TLS session and admission fails — even with no mesh involved.

---

## Phase F — Webhook **outside** the mesh

Deploy a tiny HTTPS validating webhook that always **allows** and logs the request. Injection is explicitly off (`sidecar.istio.io/inject: "false"`) so we start with a clean **1/1** pod:

```bash
oc apply -f k8s/10-admission-webhook.yaml
```

Wait until the webhook Deployment is ready:

```bash
oc rollout status deployment/admission-webhook -n admission-lab --timeout=180s
```

Confirm the pod is **1/1** (no `istio-proxy`):

```bash
oc get pods -n admission-lab
```

Register the cluster-scoped `ValidatingWebhookConfiguration`. The `sed` step injects your `caBundle` so the API server trusts our cert. (If you opened a new shell, re-run `CA_BUNDLE=$(base64 -w0 /tmp/admission-lab-certs/tls.crt)` first.)

```bash
sed "s|__CA_BUNDLE__|${CA_BUNDLE}|" k8s/11-validatingwebhook.yaml | oc apply -f -
```

Confirm the webhook configuration exists:

```bash
oc get validatingwebhookconfiguration admission-lab-pod-validate
```

Remove any leftover test pod from a previous attempt:

```bash
oc delete pod probe-pod -n admission-test --ignore-not-found
```

Create a Pod in `admission-test`. That forces the **API server** to call our webhook **before** saving the Pod:

```bash
oc apply -f k8s/12-admission-test-pod.yaml
```

Confirm the Pod was admitted and created:

```bash
oc get pod probe-pod -n admission-test
```

Check webhook logs — you should see the admission request (proof the API server called us):

```bash
oc logs -n admission-lab deploy/admission-webhook --tail=20
```

**Expect:** logs contain `admission: allow name=probe-pod`.

Delete the test Pod so Phase G can create it again cleanly:

```bash
oc delete pod probe-pod -n admission-test --ignore-not-found
```

**Takeaway:** Admission is triggered by the **API server** when the object matches the webhook rules — not by Envoy, not by istiod, not by your meshed apps.

---

## Phase G — Inject sidecar on the webhook

**Question:** What happens if the webhook **pod** sits in the mesh?

We turn injection on **without** excluding the listen port. The API server still calls the same Service, but inbound `:8443` is redirected into Envoy. The API server is not a mesh mTLS client and already speaks TLS meant for the **app** certificate — that mismatch commonly causes admission timeouts.

Label the namespace for injection and apply **STRICT** mTLS on the webhook pods. Under PERMISSIVE alone, inbound HTTPS to a meshed webhook often still works on this cluster; STRICT makes the API server → sidecar handshake fail (the API server is not an Istio mTLS client):

```bash
oc apply -f k8s/13-admission-inject-on.yaml
```

Flip the Deployment from inject `false` to `true` (do **not** `oc apply` a partial Deployment — that can wipe required fields):

```bash
oc patch deployment admission-webhook -n admission-lab --type=json -p='[
  {"op":"replace","path":"/spec/template/metadata/annotations/sidecar.istio.io~1inject","value":"true"}
]'
```

Restart so new pods are created with a sidecar:

```bash
oc rollout restart deployment/admission-webhook -n admission-lab
```

Wait for the rollout, then **wait until Terminating pods are gone** (they can still answer admission and hide the failure):

```bash
oc rollout status deployment/admission-webhook -n admission-lab --timeout=180s
oc get pods -n admission-lab
# optional: wait until only Running 2/2 pods remain
sleep 20
oc get pods -n admission-lab
```

Confirm the pod is **2/2** and annotations show inject true **without** `excludeInboundPorts`:

```bash
oc get deploy admission-webhook -n admission-lab \
  -o jsonpath='{.spec.template.metadata.annotations}' ; echo
```

Clear any old test Pod:

```bash
oc delete pod probe-pod -n admission-test --ignore-not-found
```

Try the same Pod create again. Expect it to **fail** (`failed calling webhook` / timeout / TLS). With `failurePolicy: Fail`, Kubernetes rejects the create:

```bash
oc apply -f k8s/12-admission-test-pod.yaml
```

Look at events for the admission failure message:

```bash
oc get events -n admission-test --sort-by='.lastTimestamp' | tail -20
```

Check the webhook **app** container logs. Often there is **no** new `admission: allow` line:

```bash
oc logs -n admission-lab deploy/admission-webhook -c webhook --tail=20 || true
```

**Takeaway:** The failure mode is **inbound sidecar / mTLS**, not missing ServiceEntry or Sidecar egress. Those Part 1 tools do not fix API server → webhook.

---

## Phase H — `excludeInboundPorts`

**Question:** Can a meshed webhook work if we carve the listen port out of Envoy?

Annotation `traffic.sidecar.istio.io/excludeInboundPorts: "8443"` tells the sidecar to leave that port alone so API server HTTPS hits the app directly. Useful if you *must* mesh the pod; for admission-only controllers, **Phase F (no inject)** is still simpler and safer.

Add `excludeInboundPorts` while keeping injection on:

```bash
oc patch deployment admission-webhook -n admission-lab --type=json -p='[
  {"op":"add","path":"/spec/template/metadata/annotations/traffic.sidecar.istio.io~1excludeInboundPorts","value":"8443"}
]'
```

Restart so pods pick up the new annotation:

```bash
oc rollout restart deployment/admission-webhook -n admission-lab
```

Wait for the rollout:

```bash
oc rollout status deployment/admission-webhook -n admission-lab --timeout=180s
```

Confirm the annotation is present on the pod template:

```bash
oc get deploy admission-webhook -n admission-lab \
  -o jsonpath='{.spec.template.metadata.annotations}' ; echo
```

Clear any failed test Pod from Phase G:

```bash
oc delete pod probe-pod -n admission-test --ignore-not-found
```

Create the test Pod again — expect success:

```bash
oc apply -f k8s/12-admission-test-pod.yaml
```

Confirm the Pod exists:

```bash
oc get pod probe-pod -n admission-test
```

Confirm the webhook app logged the allow again (use `-c webhook` when the sidecar is present):

```bash
oc logs -n admission-lab deploy/admission-webhook -c webhook --tail=20
```

**Expect:** `admission: allow` and a Running (or Completed) probe Pod.

**Takeaway:** Injection + exclude can work, but production guidance for admission webhooks remains: **keep them out of the mesh** unless you have a validated exception.

---

## Cleanup

Remove the validating webhook configuration **first**. If it stays registered while pods are gone or broken, creates in `admission-test` keep failing:

```bash
oc delete validatingwebhookconfiguration admission-lab-pod-validate --ignore-not-found
```

Delete the test Pod and webhook Deployment/Service/ConfigMap:

```bash
oc delete -f k8s/12-admission-test-pod.yaml --ignore-not-found
oc delete -f k8s/10-admission-webhook.yaml --ignore-not-found
```

Delete the TLS Secret and admission namespaces:

```bash
oc delete secret admission-webhook-certs -n admission-lab --ignore-not-found
oc delete namespace admission-lab admission-test --wait=false --ignore-not-found
```

Remove Part 1 mesh policy CRs (safe even if already gone):

```bash
oc delete -f k8s/05-sidecar-allow-plain.yaml --ignore-not-found
oc delete -f k8s/04-sidecar-deny-plain.yaml --ignore-not-found
oc delete -f k8s/03-serviceentry.yaml --ignore-not-found
```

Delete the Part 1 namespaces:

```bash
oc delete namespace nonmesh-lab nonmesh-plain --wait=false --ignore-not-found
```

Remove local cert files from this machine:

```bash
rm -rf /tmp/admission-lab-certs
```

---

## Troubleshooting

| Symptom | Likely cause | What to check |
|---------|--------------|---------------|
| `mesh-client` Ready **1/1** | No sidecar injection | NS labels; `oc get istio default`; container list has only `curl` |
| Plain httpbin CrashLoop, port 80 | Non-root cannot bind :80 | Keep this repo’s 8080-based image |
| Phase C still returns 200 | Sidecar CR not applied or wrong selector | `oc get sidecar -n nonmesh-lab`; pod label `app=mesh-client`; wait for push |
| Phase C/D breaks everything | Sidecar omitted istiod namespace | Egress must include your istiod NS (`maurizio-istio-system/*` here) |
| Phase A fails with TLS errors | STRICT mTLS somewhere | `oc get peerauthentication -A`; do not enable STRICT for this lab |
| Phase G/H errors after cleanup | VWC still present | Delete `admission-lab-pod-validate` |
| Phase H still fails | Old pods / missing annotation | Confirm annotation; `oc rollout restart`; new pods **2/2** |

Optional: during Part 1, inspect what the client proxy logged:

```bash
oc logs -n nonmesh-lab deploy/mesh-client -c istio-proxy --tail=50
```

---

## Checkpoint summary

| Phase | Topic | Expected |
|-------|--------|----------|
| A | Meshed → plain, no CRs | HTTP **200** |
| B | + ServiceEntry | still **200** |
| C | Sidecar deny plain NS | **fail** |
| D | Sidecar allow plain NS | **200** |
| F | Admission webhook not injected | Pod CREATE **ok** |
| G | Webhook injected | CREATE **fails** |
| H | + `excludeInboundPorts` | CREATE **ok** again |

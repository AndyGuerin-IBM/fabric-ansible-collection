# Review of the `move-ingress` plan

**Date:** 2026-10-12
**Scope:** every document in `plan/move-ingress/`, checked against the repository code (`.github/`, `roles/`, `tutorial/`, `plugins/`) and the official Envoy Gateway / Gateway API compatibility matrices.

---

## 1. Summary of the plan

| Document | Purpose |
|---|---|
| [`PRE-ANALYSIS.md`](./PRE-ANALYSIS.md) | Why move away from ingress-nginx, Fabric networking requirements (TLS passthrough, SNI, gRPC-Web), Gateway API vs Istio → **Gateway API** selected |
| [`GATEWAY-API-IMPLEMENTATIONS.md`](./GATEWAY-API-IMPLEMENTATIONS.md) | Comparison of Gateway API implementations → **Envoy Gateway** selected for CI / PoC |
| [`MIGRATION-PLAN.md`](./MIGRATION-PLAN.md) | Monolithic plan in 7 workstreams (W1 to W7) with code snippets |
| [`MIGRATION-ROADMAP.md`](./MIGRATION-ROADMAP.md) | Split into 4 independently shippable deliverables (Step 0 → 3) |
| [`MIGRATION-STEP-0.md`](./MIGRATION-STEP-0.md) | Fix CI and local test execution — marked `complete` (commit `29fd64f`) |
| [`MIGRATION-STEP-1.md`](./MIGRATION-STEP-1.md) | `ingress_type` / `expose_*` variables, nginx "expose-none" scenario (port 443 added to Services, CoreDNS rewrites, in-cluster Ansible Job) |
| [`MIGRATION-STEP-2.md`](./MIGRATION-STEP-2.md) | First Gateway API implementation: console `HTTPRoute` only |
| [`MIGRATION-STEP-3.md`](./MIGRATION-STEP-3.md) | CA / peer / orderer `TLSRoute`s, 7054 / 7050 / 7051 listeners, `api_url` port changes |
| [`MIGRATION-PREREQ-LDE.md`](./MIGRATION-PREREQ-LDE.md) | Local development environment setup (macOS, Python 3.10 venv) |
| [`PROMPTS.md`](./PROMPTS.md) | History of the prompts that produced these documents |

### Step sequence

```
Step 0: CI + LDE fixed (nginx baseline)
  └─► Step 1: expose_* / ingress_type variables, nginx expose-none scenario
        └─► Step 2: Gateway API — console only (HTTPRoute)
              └─► Step 3: Gateway API — all components (TLSRoute) + native ports
```

### Overall assessment

**Strengths:** incremental approach, the nginx path is never broken, explicit
acceptance criteria per step, solid upfront analysis of Fabric's TLS
requirements.

**Weaknesses:** **5 issues genuinely block progress** (§2). Three of them call
the design of Steps 1 and 3 into question; the other two are blocking but easy
to fix. Everything else (§3, §4) is either an implementation mistake or a
documentation inconsistency that can be fixed along the way without changing
the architecture.

| # | Issue | Step | Nature | Effort | Status |
|---|---|---|---|---|---|
| B1 | Native ports cannot work without changing the operator | 3 (and 2) | Design | High | Open |
| B2 | "Nothing exposed" is impossible on nginx as specified | 1 | Decision | — | Open |
| B3 | A Service port 443 cannot serve several FQDNs | 1 | Design | Medium | Open |
| B4 | `run-tests.sh` crashes (`PATCH_BG_PID`) | 0 | Bug | Trivial | **Fixed** — full test run to be confirmed |
| B5 | Gateway API CI cannot run (versions, KIND exposure) | 2 | Configuration | Low | Open |

---

## 2. Genuinely blocking issues 🔴

### 2.1 Design blockers

#### B1 — Step 3: native ports 7051 / 7050 / 7054 cannot work

**Finding.** The operator itself generates `api_url`, the gossip external
endpoint and the connection profiles with `:443` (which is precisely why Step 1
was reworked). The collection has no way to switch them to 7051 / 7050 / 7054
without changing the operator. Clients will therefore dial `:443` → the `https`
listener **terminates** TLS → Fabric mTLS is broken.

Sub-task 3.8 (changing `url_utils.py`) does not solve this and is based on a
misreading of the code:
[`translate_url_to_os_format`](../../plugins/module_utils/url_utils.py) is only
used by the `*_metadata` modules, and when the port is not 443 it **renames the
hostname** (`-<type>` suffix). Passing `7051` would produce wrong URLs. The
modules are also unaware of `ingress_type`.

**Impact.** Calls into question the architecture of Steps 2 and 3 (4-listener
topology, hostPorts, wildcard certificate, sub-task 3.8, port-change tutorials).

**Proposal — parity with nginx:**

- **A single `TLS` listener in `Passthrough` mode on 443** (`*.<domain>`).
- **One `TLSRoute` per hostname**: console, peer, operations, grpcweb, ca,
  orderer, admin — exactly what nginx ssl-passthrough does today.

| Removed | Cost |
|---|---|
| Port changes and sub-task 3.8 | `TLSRoute` required from Step 2 |
| 3 extra listeners + hostPorts | → Gateway API ≥ 1.5 (fine with EG v1.9) |
| Wildcard certificate + `fabric-tls-secret` Secret | |
| `BackendTLSPolicy` for the console | |
| Port-change tutorials | |

The "one port per protocol class" topology can remain a later option, once
natively supported by `fabric-operator` (sub-task 3.15).

#### B2 — Step 1: "nothing exposed through nginx" is impossible as specified

**Finding.** The **fabric-operator** creates the `Ingress` objects for CAs,
peers, orderers and the console (see PRE-ANALYSIS §4.4). No Step 1 sub-task
deletes or neutralises them.

**Source references** (upstream
[`hyperledger-labs/fabric-operator`](https://github.com/hyperledger-labs/fabric-operator),
`main` branch, checked 2026-10-12). For every component the same three-layer
pattern applies — a generic resource manager performs the actual
`client.Create`, a per-component "override" builds the per-FQDN
`IngressSpec`, and a per-component reconcile function wires the two together
and calls them on every reconcile loop:

| Layer | File | Line(s) |
|---|---|---|
| Generic `Ingress` manager — actual `client.Create()` call | [`pkg/manager/resources/ingress/manager.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/manager/resources/ingress/manager.go#L57-L71) | `Reconcile()` L57, `Client.Create(...)` **L71** |
| Factory wiring the override into the generic manager | [`pkg/manager/resources/manager/manager.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/manager/resources/manager/manager.go#L158) | `CreateIngressManager()` L158 |
| **Console** — FQDN(s) built | [`pkg/offering/k8s/console/override/ingress.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/console/override/ingress.go#L49-L56) | `CommonIngress()` L49, `consolehost` **L56** |
| **Console** — manager created / reconciled | [`pkg/offering/k8s/console/console.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/console/console.go#L81) | `CreateIngressManager(...)` L81, called from L162, `ReconcileIngressManager()` L175, `IngressManager.Reconcile(...)` L188 |
| **CA** — FQDNs built (`-ca`, `-operations`) | [`pkg/offering/k8s/ca/override/ingress.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/ca/override/ingress.go#L49-L58) | `CommonIngress()` L49, `apihost` **L57**, `operationshost` **L58** |
| **CA** — manager created / reconciled | [`pkg/offering/k8s/ca/ca.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/ca/ca.go#L83) | `CreateIngressManager(...)` L83, called from L194, `ReconcileIngressManager()` L202, `IngressManager.Reconcile(...)` L215/221 |
| **Peer** — FQDNs built (`-peer`, `-operations`, `-grpcweb`) | [`pkg/offering/k8s/peer/override/ingress.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/peer/override/ingress.go#L49-L58) | `CommonIngress()` L49, `apihost` **L56**, `operationshost` **L57**, `grpcwebhost` **L58** |
| **Peer** — manager created / reconciled | [`pkg/offering/k8s/peer/peer.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/peer/peer.go#L89) | `CreateIngressManager(...)` L89, called from L99, `ReconcileIngressManager()` L274, `IngressManager.Reconcile(...)` L287/293 |
| **Orderer** — FQDNs built (`-orderer`, `-operations`, `-grpcweb`, `-admin`) | [`pkg/offering/k8s/orderer/override/ingress.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/orderer/override/ingress.go#L50-L143) | `CommonIngress()` L50, `apihost` **L58**, `operationshost` **L59**, `grpcwebhost` **L60**, `adminhost` **L143** (gated on Fabric ≥ 2.4.1/2.5.1) |
| **Orderer** — manager created / reconciled | [`pkg/offering/k8s/orderer/node.go`](https://github.com/hyperledger-labs/fabric-operator/blob/main/pkg/offering/k8s/orderer/node.go#L74) | `CreateIngressManager(...)` L74, called from L236, `ReconcileIngressManager()` L244, `IngressManager.Reconcile(...)` L257/263 |

Each `*IngressManager.Reconcile()` call is unconditional on this `main` branch
— nothing in the operator's current config lets a caller opt out of `Ingress`
creation, which is exactly why no Step 1 sub-task can "neutralise" these
objects from the Ansible side alone (confirms B2's impact below).

**Impact.** The goal "nothing is exposed through the NGINX ingress controller"
cannot be met, and assertion 1 of sub-task 1.6 ("No external Ingress objects")
will always fail.

**Decision required before coding Step 1:** see §6.

#### B3 — Step 1: a Service port 443 cannot serve several FQDNs

**Finding.** Each component exposes several hostnames on `:443`:

| Component | Hostnames | Native ports |
|---|---|---|
| Peer | `-peer`, `-operations`, `-grpcweb` | 7051, 9443, 7443 |
| Orderer | `-orderer`, `-admin`, `-operations`, `-grpcweb` | 7050, 9443, 8443, 7443 |
| CA | `-ca`, `-operations` | 7054, 9443 |

A Service port maps to **a single** `targetPort`. Sub-task 1.4b rewrites
`-operations` to the same Service as `-peer`: `/healthz` lands on gRPC port 7051
and fails. In addition, patching operator-owned Services may be reverted on the
next reconciliation (to be verified in `fabric-operator`).

**Impact.** The "Strategic Merge Patch" approach of sub-task 1.3b cannot work
for the operations / admin / grpcweb endpoints.

**Proposal:** the collection creates **its own ClusterIP Services**, one per
FQDN:

- named after the first label of the FQDN (`<ns>-<slug>-peer`,
  `<ns>-<slug>-operations`, …);
- selector copied from the operator's Service;
- `port: 443 → targetPort: <native port>`;
- not reconciled by the operator.

**Bonus:** with `ingress_domain: <ns>.svc.<cluster_domain>`, the FQDNs generated
by the operator become real Kubernetes Service names → **no CoreDNS rewrite
needed at all** (sub-task 1.4b and most of sub-task 1.1 go away). Constraint: a
DNS label is limited to 63 characters.

### 2.2 Blockers that are easy to fix

#### B4 — Step 0: `run-tests.sh` crashes — **fixed**

`run-tests.sh` contained `wait "${PATCH_BG_PID}"`, a variable that is never
defined. With `set -u` the script stopped right after `build_network.sh build`,
the cleanup trap destroyed everything, and `join_network.sh join` /
`deploy_smart_contract.sh` never ran. Confirmed on a local run on 2026-10-12:
`build_network.sh` completed successfully (playbooks 01 → 11), then
`PATCH_BG_PID: unbound variable`.

**Fix applied:** the line was removed from
[`run-tests.sh`](../../.github/scripts/run-tests.sh) (`bash -n` passes). A full
re-run (`exit=0`, playbooks 17 and 19–23 executed) is still needed to close
this item.

Step 0 is still marked `complete` although the `TEST_RUN_ID` stamping (§3.1) is
not implemented.

#### B5 — Step 2: the Gateway API CI cannot run as written

**Versions.** The plan confuses Envoy Gateway v1.3.0 with Gateway API v1.3.
Official Envoy Gateway matrix (excerpt):

| Envoy Gateway | Gateway API | Kubernetes | End of life |
|---|---|---|---|
| v1.3 | v1.2.1 | 1.29 – 1.32 | 2025-07-30 |
| v1.5 | v1.3.0 | 1.30 – 1.33 | 2026-02-13 |
| v1.8 | v1.5.1 | 1.32 – 1.35 | 2026-11-08 |
| **v1.9** | **v1.6.1** | **1.33 – 1.36** | 2027-02-14 |

- EG v1.3 is end-of-life, and the KIND node image (`kindest/node:v1.25.3`) is
  too old for any supported version.
- `gateway-helm` installs its own CRDs → conflicts with the
  `standard-install.yaml` applied beforehand (use `--skip-crds` or let Helm
  manage them).

**Exposure.** KIND `extraPortMappings` are not enough: the Envoy Service is of
type `LoadBalancer`, and a NodePort cannot be 443. Nothing makes Envoy listen on
port 443 of the node.

**Fix:** EG v1.9 / Gateway API v1.6 / KIND node ≥ 1.33, plus an `EnvoyProxy`
resource (hostPort / hostNetwork) or `cloud-provider-kind`.

---

## 3. Implementation mistakes (fixable without changing the design) 🟠

These issues are real but can be fixed while implementing each step.

### 3.1 Step 0

- `TEST_RUN_ID` / `SHORT_TEST_RUN_ID` stamping (sub-task 0.2) is not implemented.
- Diverging versions: CI uses Python **3.9** while the LDE requires "exactly
  3.10"; CI installs Fabric **2.4.7** while the LDE downloads **2.5.15** under a
  "Fabric 2.4.7" heading.
- `fvtest.yml` only triggers on `workflow_dispatch`; Step 1 refers to running
  "on every push".
- Sub-task 0.1 (inline playbook calling `fabric_console`) does not match the
  implementation (`tutorial/00-deploy-fabric-console.yml` with an inline `IBPConsole`).
- The LDE doc does not mention two prerequisites found during the local run:
  - the collection must be rebuilt and reinstalled from the repository
    (`ansible-galaxy collection build -f && ansible-galaxy collection install … -f`),
    otherwise an outdated copy in `~/.ansible/collections` is used (it rejected
    `arch: arm64`);
  - `ANSIBLE_PYTHON_INTERPRETER` must point to `.venv/bin/python`, otherwise
    Ansible discovers a system Python without the `kubernetes` library.
- The LDE doc suggests `brew install yq`, which installs mikefarah's `yq` — not
  compatible with the `yq -yi` syntax used by the scripts. Only the Python `yq`
  from `requirements.txt` works.

### 3.2 Step 1 — variables and facts

- **`cluster_domain` discovery:** `kubectl exec deployment/coredns -- awk`
  always fails (the CoreDNS image is distroless, without `awk` or a shell;
  CoreDNS pods use `dnsPolicy: Default`, so their `resolv.conf` has no cluster
  `search` line). It also requires `kubectl` and the `pods/exec` permission.
  → Read the Corefile from the `kube-system/coredns` ConfigMap via `k8s_info`,
  or keep `cluster.local` as the default with a documented override; use `""` as
  the sentinel value.
- **Variable scope:** the defaults of `fabric_operator_crds` are not visible
  from `fabric_console`, `endorsing_organization` or `ordering_organization`
  (separate playbooks). `include_tasks: set_facts.yml` called from
  `hlfsupport_console` looks for the file in its own role.
  `ingress_domain_is_cluster_local` is used in the organization roles without
  ever being defined there.
  → Defaults in each role, or a small shared role called via `include_role`.
- **Cluster-local `ingress_domain` (sub-task 1.1b):** `<x>.svc.cluster.local` is
  not a Service FQDN (the form is `<svc>.<ns>.svc.<zone>`). It only works with
  the B3 proposal. Optional feature, not blocking.

### 3.3 Step 1 — organization roles

- Adding `kubernetes.core.k8s` tasks to `endorsing_organization` /
  `ordering_organization` introduces a dependency on a kubeconfig and the
  `kubernetes` library, whereas these roles currently only talk to the console
  REST API (contradicts MIGRATION-PLAN §1.1). → Explicit guard
  (`target == 'k8s'` or opt-in).
- `ca_name | lower | replace(' ', '-')` yields `org1-ca`; the operator produces
  `org1ca`. An ordering service has N nodes, not a single Service.
- `peer_api_url`, `ca_api_url`, `orderer_api_url` (W6) are never defined →
  register the module outputs.
- The `certificate_authority` role (sub-task 3.2, §5.6.9) does not exist: the CA
  is created inside the organization roles.

### 3.4 Step 1 — console

- `uri http://<console>.<ns>.svc.cluster.local:3000` runs on the Ansible control
  node, which cannot resolve in-cluster names.
  → Check the Deployment readiness via `k8s_info`.
- Hardcoded `cluster.local`; the `http :3000` protocol / port needs checking;
  inconsistent health path (`/health` in Step 0, `/ak/api/v3/health` in
  sub-task 1.6).
- [`roles/fabric_console/tasks/k8s/create.yml`](../../roles/fabric_console/tasks/k8s/create.yml)
  does not wait for any Ingress: there is nothing to "split". CI does not use
  this role (`00-deploy-fabric-console.yml`), so sub-task 1.3 would not be
  tested there.

### 3.5 Step 1 — expose-none CI

- Hardcoded values (`fabricinfra`, `localho.st`, `org1peer`…) whereas CI uses
  `default`, `<ip>.nip.io`, randomised names, and Org2 is missing.
  → Generate the list from the resources actually created.
- The rewrites are applied **after** the playbook, whereas `build_network.sh`
  needs connectivity **during** its execution.
- The proposed Corefile drops the `hosts { … host.ingress.internal }` block and
  the nip.io rewrite → the console no longer resolves.
- Assertions 3 to 5 test `:7051/:7050/:7054`, while real traffic goes through
  `:443`; `exit_code=$?` is never reached under `set -e`.
- In-cluster Job: read-only ConfigMap mount (the playbooks write their JSON
  identity files), flattened directory tree, 1 MiB limit, no ServiceAccount /
  RBAC.

### 3.6 Step 2

- Sub-task 2.1 waits for the `tlsroutes` CRD, which is not in the v1.3 standard
  channel → hangs (goes away with B5 / B1).
- `COREDNS_HOOK` is unnecessary: the `Gateway` is created in
  `00-deploy-fabric-console.yml`, i.e. before `run-tests.sh`. Better still:
  rewrite to the FQDN of an Envoy Service with a fixed name (via `EnvoyProxy`).
- The §5.2 script calls `apply_coredns_override` at bootstrap (contradicts
  sub-task 2.1) and uses `kubectl config view --raw` instead of
  `kind get kubeconfig`.
- Listeners use `*.{{ ingress_domain }}` (`localho.st`) whereas the components
  use `console_domain` (`nip.io` in CI). → Derive `ingress_domain` from
  `console_domain`.
- The `fabric-tls-secret` Secret is never created; a `BackendTLSPolicy` is
  needed for an `HTTPRoute` to a TLS console backend (goes away with B1).

---

## 4. Documentation inconsistencies 🟡

- Gateway API versions: the roadmap states **1.6** minimum from Step 3, but
  `MIGRATION-STEP-3.md` says "v1.5+" everywhere (title, sub-tasks 3.1 and 3.11,
  criterion 7).
- "v1.3 = the version that promotes HTTPRoute to GA" is wrong: GA since v1.0.
- "No manifest changes" is wrong for `TLSRoute`: `apiVersion`
  `v1alpha2`/`v1alpha3` → `v1`.
- Outdated deprecation timeline: `galaxy.yml` is already at **2.1.3**; removing
  nginx is a breaking change → **3.0** (semver).
- `GATEWAY-API-IMPLEMENTATIONS.md`: "EG v1.3 — TLSRoute GA" is wrong; Istio
  1.22 and Contour 1.28 are outdated; the GKE row needs rechecking.
- MIGRATION-PLAN §2.1: CA operations port is 9443 (not 7054); orderer:
  operations 8443, admin 9443.
- RBAC (sub-task 1.2 / W4): routes are created by Ansible tasks, not by the
  operator → extending the operator's ClusterRole is unnecessary.
- Sub-task 1.3 announces a "five-task block" but lists six tasks.
- `IBPConsole` is queried as `v1alpha2` in the roles but created as `v1beta1`
  in `00-deploy-fabric-console.yml`.

---

## 5. Structural improvements 🟢

1. **Single source of truth.** The steps point to `MIGRATION-PLAN §5.x`
   snippets that are now outdated (EG v1.3.0, `COREDNS_HOOK`,
   `kubectl config view`). Either make the steps self-contained and mark the
   PLAN as historical, or resynchronise it.
2. **"Decisions" section (ADR):** semantics of `expose_*`, port topology,
   target versions, single domain.
3. **Two spikes before coding Step 1:**
   - (a) `fabric-operator` reconciliation behaviour on a patched Service and on
     a deleted Ingress (drives B2 and B3);
   - (b) Envoy Gateway on KIND with TLS passthrough on 443, console included
     (validates B1 and B5).
4. **Dynamically generated tests** based on the resources actually created.

---

## 6. Decision required (B2)

On the nginx path, what does `expose_*: false` mean?

| Option | Meaning | Implication |
|---|---|---|
| **(a)** | "The collection does not depend on exposure" | The operator's Ingress objects remain. Simple and honest, but no real isolation. |
| **(b)** | "Nothing is actually exposed" | Delete or neutralise the Ingress objects → verify operator reconciliation, possibly an upstream contribution (flag in `fabric-operator`). |

Note: even with an `ingress_domain` that cannot be resolved from outside, nginx
still routes a client presenting the right SNI. Option (a) therefore offers no
security guarantee.

---

## 7. Recommended order of action

| Order | Action | Unblocks |
|---|---|---|
| 1 | ~~Fix `PATCH_BG_PID` in `run-tests.sh`~~ (done) — re-run the full test suite, then implement `TEST_RUN_ID` stamping | B4 — actual completion of Step 0 |
| 2 | Decide the semantics of `expose_*: false` on nginx | B2 |
| 3 | Spikes (a) operator and (b) Envoy Gateway passthrough on 443 | B1, B3, B5 |
| 4 | Rewrite Step 1 around collection-owned Services | B3 |
| 5 | Realign Steps 2–3: EG v1.9 / Gateway API v1.6, KIND ≥ 1.33, `EnvoyProxy`, passthrough-443 topology | B1, B5 |
| 6 | Fix the §3 items while implementing each step | — |
| 7 | Update `MIGRATION-PLAN.md`, `GATEWAY-API-IMPLEMENTATIONS.md` and the roadmap (§4) | — |

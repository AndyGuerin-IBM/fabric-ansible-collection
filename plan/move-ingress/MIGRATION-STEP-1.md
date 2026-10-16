# Step 1 — Expose Options with NGINX Ingress Controller

**Roadmap reference:** [`MIGRATION-ROADMAP.md`](./MIGRATION-ROADMAP.md) — Step 1
**Plan reference:** [`MIGRATION-PLAN.md`](./MIGRATION-PLAN.md) — W1, W4, partial W5, partial W3, partial W7
**Prerequisite:** [`MIGRATION-STEP-0.md`](./MIGRATION-STEP-0.md) (Baseline CI & Test Runner Fixes)
**Status:** `[ ] pending`

---

## Overview

This deliverable builds on the working baseline established in **Step 0** ([`MIGRATION-STEP-0.md`](./MIGRATION-STEP-0.md)). It introduces all new Ansible variables (`ingress_type`, `expose_*`) and makes the collection's console wait-logic aware of the `expose_console` flag, while the **nginx ingress controller remains the only supported and tested ingress backend**. No Gateway API resources, templates, or CRDs are introduced yet.

The primary goals of this step are:
1. Establish the stable variable schema that Steps 2 and 3 will build on.
2. Prove there is no regression in the working nginx-backed test suite (Scenario B baseline from Step 0).
3. Validate the extreme opposite scenario: a deployment where nothing is exposed
   through the NGINX ingress controller (`expose_console: false`,
   `expose_ca: false`, `expose_peer: false`, `expose_orderer: false`).

---

## Sub-task 1.1 — Variable abstraction (`fabric_operator_crds` defaults)

**Intent:** Introduce every new variable with safe defaults so all existing
playbooks continue to work without modification. This sub-task also introduces
two new variables — `ingress_domain` and `cluster_domain` — and a derived fact
`ingress_domain_is_cluster_local` that later sub-tasks (1.1b, 1.4b) use to
decide whether CoreDNS rewrites are needed. The per-endpoint Services of
sub-task 1.3b are needed in **both** cases.

**Expected outcomes:**
- `roles/fabric_operator_crds/defaults/main.yml` contains `ingress_type: nginx`,
  the six `expose_*` flags, the three port variables, `gateway_class_name`,
  `ingress_domain`, and `cluster_domain`.
- A new task file `roles/fabric_operator_crds/tasks/k8s/set_facts.yml` resolves
  `cluster_domain`. It always tries, as a best effort, to read the domain
  from the `kubernetes` plugin line of the Corefile in the
  `kube-system/coredns` ConfigMap (`kubernetes.core.k8s_info`, no `kubectl`,
  no `pods/exec`), then reconciles it with the user value: a mismatch is an
  error; an undiscoverable domain is a warning when the user set one and an
  error when they did not.
- `ansible-lint` and `yamllint` pass on all modified files.
- All existing tests pass without setting any new variable.

**New variables:**

`ingress_domain` — the DNS domain suffix used when constructing component
hostnames (e.g. `localho.st`, `example.com`). The operator templates component
FQDNs as `<namespace>-<slug>-<role>.<ingress_domain>`. Default: `localho.st`.

`cluster_domain` — the Kubernetes cluster DNS zone (e.g. `cluster.local`).
Used by sub-task 1.1b to detect cluster-local deployments and by sub-task 1.4b
as a literal value in CoreDNS rewrite target FQDNs
(`<svc>.<namespace>.svc.<cluster_domain>`). Default: `""` (sentinel meaning
"discover it"; see below).

**Resolution of `cluster_domain`:**

The earlier design ran `kubectl exec deployment/coredns -- awk … /etc/resolv.conf`.
That cannot work (REVIEW-MIGRATION-PLAN-STEP-1.md, "Variables and facts"):

- the CoreDNS image is distroless: there is no `awk` and no shell to exec into;
- CoreDNS pods use `dnsPolicy: Default`, so their `resolv.conf` is the node's
  and has no cluster `search` line anyway;
- it needs the `kubectl` binary and the `pods/exec` permission, which the
  collection otherwise never requires.

The cluster domain is instead read from the **source of truth CoreDNS itself
uses**: the Corefile stored in the `kube-system/coredns` ConfigMap. Its
`kubernetes` plugin line lists the zones CoreDNS is authoritative for, cluster
domain first, then the reverse zones:

```
kubernetes cluster.local in-addr.arpa ip6.arpa {
```

This only needs `get` on one ConfigMap through `kubernetes.core.k8s_info`, the
module family the k8s roles already use.

The lookup **always runs**, as a best effort: the discovered domain is the
first non-`*.arpa` zone of the `kubernetes` line of
`kube-system/coredns` → `data.Corefile`, trailing dot removed. It is then
reconciled with the user value:

| Lookup result | `cluster_domain` set by the user | Outcome |
|---|---|---|
| discovered `D` | empty (default) | `cluster_domain = D` |
| discovered `D` | `D` | `cluster_domain = D` (double-checked) |
| discovered `D` | `X ≠ D` | **fail**: names both values, asks the user to fix or remove the override |
| not discoverable | `X` | **warning**: domain could not be verified, trusting `X` |
| not discoverable | empty (default) | **fail**: asks the user to set `cluster_domain` |

"Not discoverable" covers a ConfigMap that is absent, unreadable (RBAC) or
has no `kubernetes` line: GKE with kube-dns, OpenShift
(`openshift-dns/dns-default`), CoreDNS deployed under another name, or a
restricted user. Comparison is case-insensitive and ignores a trailing dot on
either side (`Cluster.Local.` equals `cluster.local`).

The role never guesses `cluster.local`. A wrong cluster domain would only
surface much later, as CoreDNS rewrites (sub-task 1.4b) pointing at
non-existent Service FQDNs, or as a cluster-local `ingress_domain` silently not
recognised (sub-task 1.1b). That is also why a mismatch is an error rather
than a warning: when the cluster states its domain, it is right.

```yaml
# roles/fabric_operator_crds/tasks/k8s/set_facts.yml

- name: Read the CoreDNS Corefile to discover the cluster domain
  kubernetes.core.k8s_info:
    api_version: v1
    kind: ConfigMap
    namespace: kube-system
    name: coredns
  register: _coredns_cm
  failed_when: false   # missing ConfigMap or RBAC denial handled below

- name: Normalise the user and discovered cluster domains
  ansible.builtin.set_fact:
    _user_cluster_domain: >-
      {{ cluster_domain | default('', true) | lower | regex_replace('\.$', '') }}
    _discovered_cluster_domain: >-
      {{ (_coredns_cm.resources | default([]) | first | default({}))
           .get('data', {}).get('Corefile', '')
         | regex_findall('(?m)^\s*kubernetes\s+([^{\n]+)')
         | map('split') | flatten
         | reject('search', '\.arpa\.?$')
         | map('lower') | map('regex_replace', '\.$', '')
         | first | default('') }}
    _cluster_domain_lookup_error: >-
      {{ _coredns_cm.msg | default('no kubernetes plugin line in the Corefile') }}

- name: Fail when the user cluster_domain contradicts the cluster
  ansible.builtin.fail:
    msg: >-
      cluster_domain='{{ _user_cluster_domain }}' does not match the cluster
      domain '{{ _discovered_cluster_domain }}' declared in the
      kube-system/coredns ConfigMap. Set cluster_domain to
      '{{ _discovered_cluster_domain }}', or remove it from your vars file.
  when:
    - _discovered_cluster_domain != ''
    - _user_cluster_domain != ''
    - _user_cluster_domain != _discovered_cluster_domain

- name: Fail when the cluster domain is neither set nor discoverable
  ansible.builtin.fail:
    msg: >-
      Could not read the cluster domain from the kube-system/coredns ConfigMap
      ({{ _cluster_domain_lookup_error }}). Set cluster_domain explicitly in
      your vars file (usually 'cluster.local'; check with your cluster
      administrator or the kubelet --cluster-domain setting).
  when:
    - _discovered_cluster_domain == ''
    - _user_cluster_domain == ''

- name: Warn that the user cluster_domain could not be verified
  ansible.builtin.debug:
    msg: >-
      WARNING: could not read the cluster domain from the kube-system/coredns
      ConfigMap ({{ _cluster_domain_lookup_error }}). Trusting
      cluster_domain='{{ _user_cluster_domain }}' as supplied.
  when:
    - _discovered_cluster_domain == ''
    - _user_cluster_domain != ''

- name: Set the effective cluster_domain
  ansible.builtin.set_fact:
    cluster_domain: "{{ _discovered_cluster_domain or _user_cluster_domain }}"

# Only <namespace>.svc.<cluster_domain> is a usable cluster-local domain: the
# FQDN <ns>-<cr>-<endpoint>.<ns>.svc.<cluster_domain> is then exactly the FQDN
# of the per-endpoint Service created by sub-task 1.3b.
- name: Set ingress_domain_is_cluster_local fact
  ansible.builtin.set_fact:
    ingress_domain_is_cluster_local: >-
      {{ ingress_domain == k8s_namespace + '.svc.' + cluster_domain }}
    ingress_domain_is_unsupported_cluster_local: >-
      {{ ingress_domain != k8s_namespace + '.svc.' + cluster_domain
         and (ingress_domain == cluster_domain
              or ingress_domain.endswith('.' + cluster_domain)) }}
```

**Todo list:**
- [ ] Add `ingress_type: nginx` to
  `roles/fabric_operator_crds/defaults/main.yml`.
- [ ] Add `expose_console: true`, `expose_ca: true`, `expose_peer: true`,
  `expose_orderer: true`, `expose_peer_operations: false`,
  `expose_orderer_operations: false`, `expose_grpcweb: false`.
- [ ] Add `gateway_class_name: fabric-envoy-gateway`,
  `ingress_ca_port: 7054`, `ingress_grpc_orderer_port: 7050`,
  `ingress_grpc_peer_port: 7051` (consumed in later steps; inert here).
- [ ] Add the following two new variables with inline comments:
  ```yaml
  # DNS domain suffix used to construct component hostnames.
  # Examples: localho.st (local dev), example.com (production).
  # Set to <namespace>.svc.<cluster_domain> (e.g. fabricinfra.svc.cluster.local)
  # when all components stay in-cluster and all expose_* are false: component
  # FQDNs are then the names of the per-endpoint Services (sub-task 1.3b) and
  # CoreDNS rewrites are unnecessary. Any other *.<cluster_domain> value, or
  # mixing a cluster-local ingress_domain with any expose_*: true, is an error
  # (caught at role entry by sub-task 1.1b).
  ingress_domain: localho.st

  # Kubernetes cluster DNS domain. The role always tries to read it from the
  # kubernetes plugin line of the kube-system/coredns ConfigMap:
  # - empty: the discovered value is used;
  # - set: it must match the discovered value, otherwise the play fails.
  # When that ConfigMap is absent or unreadable (GKE kube-dns, OpenShift,
  # restricted RBAC) a set value is trusted with a warning, and an empty one
  # fails the play: set it explicitly (usually cluster.local).
  cluster_domain: ""
  ```
- [ ] Create `roles/fabric_operator_crds/tasks/k8s/set_facts.yml` with the
  tasks shown above (read ConfigMap, normalise, fail-on-mismatch,
  fail-when-unset-and-undiscoverable, warn-when-unverifiable, set effective
  `cluster_domain`, set `ingress_domain_is_cluster_local`).
- [ ] Test the extraction expression against the Corefiles of KIND,
  k3s, EKS and AKS (all `kubernetes cluster.local in-addr.arpa ip6.arpa`)
  and a Corefile with a custom domain.
- [ ] Test the five rows of the reconciliation table, including a
  case/trailing-dot-only difference (`Cluster.Local.` vs `cluster.local`,
  which must pass).
- [ ] Include `set_facts.yml` at the top of
  `roles/fabric_operator_crds/tasks/k8s/create.yml` and the equivalent
  `create.yml` in `roles/hlfsupport_console`, before any task that branches on
  `expose_*` or `ingress_domain_is_cluster_local`:
  ```yaml
  - ansible.builtin.include_tasks: set_facts.yml
  ```
- [ ] Add inline comments explaining every variable's purpose and when to
  override it, as specified in MIGRATION-PLAN.md §5.1.
- [ ] Run `ansible-lint` and `yamllint` on all modified and new files.

**Relevant context:**
- The defaults file must not contain conditional logic — only `key: value`
  defaults. All conditional logic lives in `set_facts.yml`.
- The `""` sentinel is how the role tells "user set a value" from "user left
  the default". A user value is double-checked against the Corefile whenever
  the Corefile is readable; it is only trusted blindly (with a warning) when
  it is not.
- After `set_facts.yml`, `cluster_domain` is never empty. Every later task can
  use it directly. **Caveat:** this relies on `set_fact` overriding the
  variable, which does not happen when `cluster_domain` is passed as an extra
  var (`-e`, highest precedence): an empty `-e cluster_domain=` would then
  stay empty after discovery. Pass it from a vars file (as `run-tests.sh`
  does with `common-vars.yml`, MIGRATION-PLAN.md §5.3.1), or, if `-e` support
  is required, rename the effective fact (e.g. `cluster_domain_effective`) and
  use it in sub-tasks 1.1b and 1.4b.
- Reverse zones (`in-addr.arpa`, `ip6.arpa`) are filtered out rather than
  relying on position, because some distributions add extra zones to the
  same `kubernetes` line.
- `ingress_domain_is_cluster_local` is consumed by sub-tasks 1.1b and 1.4b;
  `ingress_domain_is_unsupported_cluster_local` by sub-task 1.1b only.
  Sub-task 1.3b runs regardless of either fact.
- The lookup needs a valid kubeconfig on the Ansible control node, which is
  already a prerequisite for the k8s roles, and `get` on
  `configmaps/coredns` in `kube-system`. Without that permission, setting
  `cluster_domain` is enough (warning, no extra RBAC needed); leaving it empty
  fails with the "set cluster_domain" message.

---

## Sub-task 1.1b — Cluster-local domain validation guard

**Intent:** When `ingress_domain` is a cluster-local suffix (detected by
`ingress_domain_is_cluster_local: true` from sub-task 1.1, i.e.
`ingress_domain == <namespace>.svc.<cluster_domain>`), every component FQDN
`<ns>-<cr>-<endpoint>.<ns>.svc.<cluster_domain>` is exactly the FQDN of the
per-endpoint Service created by sub-task 1.3b. CoreDNS resolves them without
any rewrite rule, and no Ingress object is needed or meaningful. The
following cases must be enforced at role-entry time:

| `ingress_domain` | any `expose_*: true` | Action |
|---|---|---|
| `<namespace>.svc.<cluster_domain>` | no (all `false`) | Create per-endpoint Services (1.3b); skip CoreDNS rewrites (1.4b) |
| `<namespace>.svc.<cluster_domain>` | yes (at least one) | **Fail fast** with an actionable error message |
| any other `*.<cluster_domain>` (e.g. `svc.cluster.local`, `other-ns.svc.cluster.local`) | any | **Fail fast**: such FQDNs match no Service name |
| external (e.g. `localho.st`) | any | Normal path; no change |

**Expected outcomes:**
- When `ingress_domain` is `<namespace>.svc.<cluster_domain>` and all
  `expose_*` are `false`, the play continues without error, sub-task 1.3b
  creates the per-endpoint Services, and sub-task 1.4b is skipped.
- When `ingress_domain` is any other cluster-local value, the play fails
  immediately and the error names the only supported form.
- When `ingress_domain` is cluster-local and any `expose_*` is `true`, the play
  fails immediately with a clear message naming which flags are in conflict.
- The guard is a no-op for all standard (non-cluster-local) `ingress_domain`
  values.

**Concrete task YAML** — add to `set_facts.yml` (or a dedicated guard block
included immediately after `set_facts.yml` in each role's `create.yml`):

```yaml
- name: Fail when ingress_domain is a cluster-local value other than <ns>.svc.<cluster_domain>
  ansible.builtin.fail:
    msg: >-
      ingress_domain='{{ ingress_domain }}' is inside the cluster domain
      '{{ cluster_domain }}' but component FQDNs built from it match no
      Kubernetes Service. The only supported cluster-local value is
      '{{ k8s_namespace }}.svc.{{ cluster_domain }}'.
  when: ingress_domain_is_unsupported_cluster_local | bool

- name: Collect expose_* flags that are true (for error reporting)
  ansible.builtin.set_fact:
    _expose_flags_enabled: >-
      {{
        (['expose_console'] if expose_console | bool else [])
        + (['expose_ca']      if expose_ca      | bool else [])
        + (['expose_peer']    if expose_peer     | bool else [])
        + (['expose_orderer'] if expose_orderer  | bool else [])
      }}
  when: ingress_domain_is_cluster_local | bool

- name: Fail when cluster-local ingress_domain is combined with expose_* flags
  ansible.builtin.fail:
    msg: >-
      ingress_domain='{{ ingress_domain }}' is a cluster-local domain
      (cluster_domain='{{ cluster_domain }}'), which means no external Ingress
      will be created. The following expose_* flags are set to true, which is
      incompatible with a cluster-local ingress_domain:
        {{ _expose_flags_enabled | join(', ') }}
      Either set all expose_* flags to false, or use an external ingress_domain
      (e.g. localho.st, example.com).
  when:
    - ingress_domain_is_cluster_local | bool
    - _expose_flags_enabled | length > 0
```

**Todo list:**
- [ ] Append the three tasks above to
  `roles/fabric_operator_crds/tasks/k8s/set_facts.yml` (after the
  `ingress_domain_is_cluster_local` fact-setting task from sub-task 1.1).
- [ ] Verify the same guard applies in `roles/hlfsupport_console` — since both
  roles include `set_facts.yml`, no duplicate code is needed.
- [ ] Write a unit test (using `ansible-playbook --check` or `molecule`) that:
  - passes with `ingress_domain: <ns>.svc.cluster.local` + all `expose_*: false`
  - fails with `ingress_domain: <ns>.svc.cluster.local` + `expose_console: true`
  - fails with `ingress_domain: svc.cluster.local` (any `expose_*`)
  - passes with `ingress_domain: localho.st` + any `expose_*` combination
- [ ] Run `ansible-lint` on the updated `set_facts.yml`.

**Relevant context:**
- `_expose_flags_enabled` is a local helper fact used only for the error message;
  it is intentionally not reused elsewhere.
- `expose_peer_operations`, `expose_orderer_operations`, and `expose_grpcweb`
  are omitted from the check because they are sub-flags of `expose_peer` /
  `expose_orderer` — if those parent flags are `false`, the sub-flags are
  irrelevant; if the parent flags are `true`, the parent-flag check fires first.
- Sub-task 1.4b skips its CoreDNS rewrites when the domain is cluster-local;
  sub-task 1.3b does **not** skip (its Services are what makes cluster-local
  FQDNs resolvable). This sub-task only handles the hard-error cases.

---

## Sub-task 1.2 — RBAC extension

**Intent:** Add `gateway.networking.k8s.io` resource permissions to both cluster
role templates. This is additive and harmless when Gateway API CRDs are not
installed; applying it now avoids a diff in Step 2.

**Expected outcomes:**
- Both cluster role templates include the `gateway.networking.k8s.io` rule block.
- Existing integration tests still pass (the new rules are never exercised on
  the nginx path).
- `yamllint` passes on both modified files.

**Todo list:**
- [ ] Add the `gateway.networking.k8s.io` rule block to
  `roles/fabric_operator_crds/templates/k8s/rbac/hlf-operator-clusterrole.yaml`
  after the existing `networking.k8s.io` block.
- [ ] Add the same rule block to
  `roles/hlfsupport_console/templates/k8s/cluster_role.yml.j2`.
- [ ] Verify the rule block covers `gateways`, `gatewayclasses`, `httproutes`,
  `tlsroutes`, and `referencegrants` with the verbs listed in
  MIGRATION-PLAN.md §5.4.
- [ ] Run `yamllint` on both modified templates.

**Relevant context:**
- Full rule block content: MIGRATION-PLAN.md §5.4
- Files: `roles/fabric_operator_crds/templates/k8s/rbac/hlf-operator-clusterrole.yaml`
  and `roles/hlfsupport_console/templates/k8s/cluster_role.yml.j2`

---

## Sub-task 1.3 — Console wait-logic for `expose_console` flag

**Intent:** Split the existing monolithic console-wait block into
`expose_console: true` and `expose_console: false` branches. When
`expose_console: false` the collection skips route/ingress discovery, polls the
in-cluster ClusterIP Service URL directly, and prints an informational notice
instead of a public URL.

**Expected outcomes:**
- `roles/hlfsupport_console/tasks/k8s/create.yml` and
  `roles/fabric_console/tasks/k8s/create.yml` handle `expose_console: false`
  correctly on the nginx path.
- When `expose_console: true` (the default) the existing behaviour is preserved.
- When `expose_console: false` the in-cluster URL
  `http://{{ console }}.{{ namespace }}.svc.cluster.local:3000` is used for the
  health-check and a notice is printed.

**Todo list:**
- [ ] In `roles/hlfsupport_console/tasks/k8s/create.yml`, locate the existing
  three tasks: "Wait for console Ingress to exist", "Set console URL", and
  "Wait for console to respond".
- [ ] Replace them with the five-task conditional block from
  MIGRATION-PLAN.md §5.5:
  - Nginx `Wait for console Ingress` guarded by
    `ingress_type == 'nginx' and expose_console | bool`.
  - Nginx `Set console URL from Ingress` with same guard.
  - `Wait for console to respond (in-cluster Service URL)` guarded by
    `not expose_console | bool`.
  - `Wait for console to respond (public URL)` guarded by
    `expose_console | bool`.
  - `Print console URL` guarded by `expose_console | bool`.
  - `Print console exposition notice` guarded by `not expose_console | bool`.
- [ ] Apply the same pattern to
  `roles/fabric_console/tasks/k8s/create.yml` (line 57 area).
- [ ] Do **not** add any Gateway API (`ingress_type == 'gateway-api'`) branches
  yet — those belong in Step 2.
- [ ] Run `ansible-lint` on both modified task files.

**Relevant context:**
- Full task YAML for all five tasks: MIGRATION-PLAN.md §5.5
- Note: the Gateway API `Wait for console HTTPRoute` tasks should be
  **omitted** from this step; add them as `when: false` stubs is unnecessary.
- In-cluster Service URL pattern: `http://{{ console }}.{{ namespace }}.svc.cluster.local:3000`

---

## Sub-task 1.3b — One collection-owned ClusterIP Service per endpoint (`expose-none` compatibility)

**Intent:** The Fabric Operator encodes `<fqdn>:443` for **every** endpoint of
every node in Custom Resources, ConfigMaps, connection profiles and console
registry entries (`api_url`, `operations_url`, `grpcwp_url`, `osnadmin_url`).
When `expose_*: false`, those FQDNs must still reach the right container port
in-cluster, without nginx.

A single Service per node cannot do this: each node advertises **several**
endpoints on `:443`, and a Service port maps `443` to exactly **one**
`targetPort`. Adding `443 → 7051` to the operator's peer Service would send
`-operations:443` to the gRPC port. That would break the console's status
checks and its grpcweb proxy, the collection's `/healthz` waits, and
`osnadmin` channel joins
(see [REVIEW-MIGRATION-PLAN-STEP-1.md](./REVIEW-MIGRATION-PLAN-STEP-1.md) B3).

The collection therefore creates **its own ClusterIP Service per endpoint**
(per node × endpoint type), each mapping `443` to that endpoint's native
port. Each Service is paired with one CoreDNS rewrite per endpoint type
(sub-task 1.4b). The operator's own Services are **never modified**, so
operator reconciliation cannot revert anything.

**Endpoint → Service mapping** (one row = one Service per node):

| Component | Endpoint type (FQDN suffix) | Console URL field | `port` | `targetPort` |
|---|---|---|---|---|
| CA      | `ca`         | `api_url`        | 443 | 7054 |
| CA      | `operations` | `operations_url` | 443 | 9443 |
| Peer    | `peer`       | `api_url`        | 443 | 7051 |
| Peer    | `operations` | `operations_url` | 443 | 9443 |
| Peer    | `grpcweb`    | `grpcwp_url`     | 443 | 7443 |
| Orderer | `orderer`    | `api_url`        | 443 | 7050 |
| Orderer | `admin`      | `osnadmin_url`   | 443 | 9443 |
| Orderer | `operations` | `operations_url` | 443 | 8443 |
| Orderer | `grpcweb`    | `grpcwp_url`     | 443 | 7443 |

**Naming rule.** The operator builds each FQDN as
`<namespace>-<cr_name>-<endpoint>.<ingress_domain>`. The collection names
each Service after the **first DNS label** of that FQDN:

```
Service name:  <namespace>-<cr_name>-<endpoint>        e.g. default-org1peer-operations
Service FQDN:  <namespace>-<cr_name>-<endpoint>.<namespace>.svc.<cluster_domain>
```

As a result:
- CoreDNS needs **one** regex rewrite per endpoint type
  (`<ns>-*-<endpoint>.<ingress_domain>` → `<same label>.<ns>.svc.<cluster_domain>`),
  not one rule per node. The rules can be written before any node exists,
  which matters because each create module polls `operations_url/healthz`
  **inside** its own task (see `wait_for()` in
  `plugins/module_utils/ordering_services.py`). The Service and the rewrite
  must therefore exist before the module call returns.
- With `ingress_domain: <namespace>.svc.<cluster_domain>` (sub-task 1.1b), the
  operator's FQDNs **are** these Service FQDNs: no rewrite at all.
- Each Service name is a valid DNS-1035 label (≤ 63 chars, starts with a
  letter) because it is also the first label of an FQDN the operator already
  generates. An `assert` still enforces this.

**Lifecycle.** The Services are created **before** the corresponding
`certificate_authority` / `peer` / `ordering_service` module call. Until the
operator starts the pods, a Service has no endpoints, which is harmless. The
module's own health wait then succeeds through the new Service. After the
module returns, a verification task checks every URL the console reports
(`api_url`, `operations_url`, `grpcwp_url`, `osnadmin_url`) against the set
of created Services. This catches a missing endpoint type that the health
wait does not exercise (grpcweb, admin).

**Facts to confirm in the operator spike** (REVIEW §Recommended order,
action 3). They are encoded as role defaults so that a wrong guess means a
default change, not a redesign:

| # | Assumption | Default encoding |
|---|---|---|
| S1 | The operator CR name is the display name lowercased with every non-`[a-z0-9]` character removed (`Org1 CA` → `org1ca`). | `k8s_endpoint_services_cr_name_regex: '[^a-z0-9]'` |
| S2 | Ordering node CR names are `<ordering service cr_name>node<i>`, `i` = 1..N. | `k8s_endpoint_services_orderer_node_suffix: 'node'` |
| S3 | Operator pods carry the label `app: <cr_name>`, as used by the operator's own Service selector. | `k8s_endpoint_services_selector_key: app` |
| S4 | Node TLS certificates already carry every endpoint FQDN as a SAN. nginx runs in SSL-passthrough mode today, so this is low risk. | — (no change expected) |

### New internal role `k8s_endpoint_services`

The three organization roles are separate playbooks and cannot share task
files, so the logic lives in a small role called via `include_role`. Its
Kubernetes dependency (`kubernetes.core`, a kubeconfig) is pulled in **only**
when a component is not exposed. The REST-only path of the organization roles
stays unchanged.

`roles/k8s_endpoint_services/defaults/main.yml`:

```yaml
k8s_endpoint_services_namespace: "{{ k8s_namespace | default('default') }}"
# Kind of component the Services are created for: ca | peer | orderer.
k8s_endpoint_services_component: ""
# Operator CR names, one per node (see S1/S2 in MIGRATION-STEP-1.md).
k8s_endpoint_services_cr_names: []
k8s_endpoint_services_cr_name_regex: '[^a-z0-9]'
k8s_endpoint_services_orderer_node_suffix: node
k8s_endpoint_services_selector_key: app
# Endpoint types per component and the native container port each maps to.
k8s_endpoint_services_endpoints:
  ca:
    - { endpoint: ca, target_port: 7054 }
    - { endpoint: operations, target_port: 9443 }
  peer:
    - { endpoint: peer, target_port: 7051 }
    - { endpoint: operations, target_port: 9443 }
    - { endpoint: grpcweb, target_port: 7443 }
  orderer:
    - { endpoint: orderer, target_port: 7050 }
    - { endpoint: admin, target_port: 9443 }
    - { endpoint: operations, target_port: 8443 }
    - { endpoint: grpcweb, target_port: 7443 }
# Console URLs to verify after the module call (tasks_from: verify).
k8s_endpoint_services_urls: []
```

`roles/k8s_endpoint_services/tasks/main.yml` (create):

```yaml
- name: Check every Service name is a valid DNS-1035 label
  ansible.builtin.assert:
    that:
      - _svc_name is match('^[a-z]([-a-z0-9]*[a-z0-9])?$')
      - _svc_name | length <= 63
    fail_msg: >-
      Service name '{{ _svc_name }}' is not a valid DNS-1035 label. Shorten the
      namespace or the component display name.
    quiet: true
  loop: "{{ k8s_endpoint_services_cr_names | product(k8s_endpoint_services_endpoints[k8s_endpoint_services_component]) | list }}"
  vars:
    _svc_name: "{{ k8s_endpoint_services_namespace }}-{{ item.0 }}-{{ item.1.endpoint }}"

- name: Create one ClusterIP Service per endpoint
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Service
      metadata:
        name: "{{ _svc_name }}"
        namespace: "{{ k8s_endpoint_services_namespace }}"
        labels:
          app.kubernetes.io/managed-by: fabric-ansible-collection
          fabric-ansible-collection/component: "{{ k8s_endpoint_services_component }}"
          fabric-ansible-collection/instance: "{{ item.0 }}"
          fabric-ansible-collection/endpoint: "{{ item.1.endpoint }}"
      spec:
        type: ClusterIP
        selector: "{{ {k8s_endpoint_services_selector_key: item.0} }}"
        ports:
          - name: https
            port: 443
            # Must stay an int: a string targetPort is a *named* port.
            targetPort: "{{ item.1.target_port | int }}"
            protocol: TCP
  loop: "{{ k8s_endpoint_services_cr_names | product(k8s_endpoint_services_endpoints[k8s_endpoint_services_component]) | list }}"
  loop_control:
    label: "{{ _svc_name }}"
  vars:
    _svc_name: "{{ k8s_endpoint_services_namespace }}-{{ item.0 }}-{{ item.1.endpoint }}"
```

`roles/k8s_endpoint_services/tasks/verify.yml`:

```yaml
- name: Assert every console endpoint URL has a matching per-endpoint Service
  ansible.builtin.assert:
    that:
      - (item | urlsplit('hostname')).split('.') | first in _expected_names
    fail_msg: >-
      The console advertises '{{ item }}' but no Service named
      '{{ (item | urlsplit('hostname')).split('.') | first }}' was created.
      Check assumptions S1–S3 in MIGRATION-STEP-1.md sub-task 1.3b.
    quiet: true
  loop: "{{ k8s_endpoint_services_urls | select | list }}"
  vars:
    _expected_names: >-
      {{ k8s_endpoint_services_cr_names
         | product(k8s_endpoint_services_endpoints[k8s_endpoint_services_component] | map(attribute='endpoint'))
         | map('join', '-')
         | map('regex_replace', '^', k8s_endpoint_services_namespace ~ '-')
         | list }}
```

`roles/k8s_endpoint_services/tasks/delete.yml`:

```yaml
- name: Delete the per-endpoint Services of the given instances
  kubernetes.core.k8s:
    state: absent
    kind: Service
    namespace: "{{ k8s_endpoint_services_namespace }}"
    label_selectors:
      - app.kubernetes.io/managed-by=fabric-ansible-collection
      - fabric-ansible-collection/instance={{ item }}
  loop: "{{ k8s_endpoint_services_cr_names }}"
```

### Calls from the organization roles

`roles/endorsing_organization/tasks/create.yml`:

```yaml
- name: Create per-endpoint Services for the CA (expose-none)
  ansible.builtin.include_role:
    name: hyperledger.fabric_ansible_collection.k8s_endpoint_services
  vars:
    k8s_endpoint_services_component: ca
    k8s_endpoint_services_cr_names:
      - "{{ ca_name | lower | regex_replace('[^a-z0-9]', '') }}"
  when: not expose_ca | default(true) | bool

- name: Create certificate authority          # existing task, add `register`
  hyperledger.fabric_ansible_collection.certificate_authority: ...
  register: endorsing_organization_ca

- name: Verify per-endpoint Services for the CA (expose-none)
  ansible.builtin.include_role:
    name: hyperledger.fabric_ansible_collection.k8s_endpoint_services
    tasks_from: verify
  vars:
    k8s_endpoint_services_component: ca
    k8s_endpoint_services_cr_names:
      - "{{ ca_name | lower | regex_replace('[^a-z0-9]', '') }}"
    k8s_endpoint_services_urls:
      - "{{ endorsing_organization_ca.certificate_authority.api_url }}"
      - "{{ endorsing_organization_ca.certificate_authority.operations_url }}"
  when: not expose_ca | default(true) | bool
```

Same pattern for the peers (before *Create peer* / *Create multiple peers*):

```yaml
    k8s_endpoint_services_component: peer
    k8s_endpoint_services_cr_names: >-
      {{ ([peer_name] if peers == 1
          else range(1, peers + 1) | map('string')
               | map('regex_replace', '^', peer_name) | list)
         | map('lower') | map('regex_replace', '[^a-z0-9]', '') | list }}
```

Verify with `api_url`, `operations_url` and `grpcwp_url` of each registered
peer. For *Create multiple peers*, use the `results` list.

`roles/ordering_organization/tasks/create.yml`: the same CA block, plus,
before *Create ordering service*:

```yaml
    k8s_endpoint_services_component: orderer
    k8s_endpoint_services_cr_names: >-
      {{ range(1, ordering_service_nodes + 1) | map('string')
         | map('regex_replace', '^', (ordering_service_name | lower
               | regex_replace('[^a-z0-9]', '')) ~ 'node')
         | list }}
```

After the module call, run the verify step with `api_url`, `operations_url`,
`grpcwp_url` and `osnadmin_url` of every element of the registered
`ordering_service` list. `osnadmin_url` is empty on Fabric < 2.4.1, and
`select` drops empty values.

The `delete.yml` of each organization role calls
`tasks_from: delete` with the same `cr_names`, guarded by the same `when`.

**Expected outcomes:**
- With `expose_ca/peer/orderer: false`, the namespace contains one Service per
  row of the mapping table for every node, each listening on `443` only.
- The operator's own Services are byte-for-byte unchanged.
- `curl -k https://<ns>-<peer>-operations.<ingress_domain>/healthz` from an
  in-cluster pod returns `{"status":"OK"}` (port 9443 reached, not 7051).
- The module health waits pass without nginx in the path.
- The verify step fails loudly (naming S1–S3) when the console advertises an
  endpoint without a matching Service.
- `ansible-lint` passes on the new role and all modified task files.

**Todo list:**
- [ ] Create `roles/k8s_endpoint_services/` (`defaults/main.yml`,
  `tasks/main.yml`, `tasks/verify.yml`, `tasks/delete.yml`, `meta/main.yml`)
  with the content above.
- [ ] Add the create / verify blocks around the CA and peer module calls in
  `roles/endorsing_organization/tasks/create.yml`, and register the module
  outputs (`endorsing_organization_ca`, `endorsing_organization_peer`,
  `endorsing_organization_peers`).
- [ ] Add the create / verify blocks around the CA and ordering-service
  module calls in `roles/ordering_organization/tasks/create.yml`, and
  register the module outputs.
- [ ] Add the delete calls to both organization roles' `delete.yml`.
- [ ] Run the operator spike and adjust the S1–S3 defaults if needed.
- [ ] Document the new role in `docs/source/roles/` (internal, but its
  defaults are user-overridable).
- [ ] Run `ansible-lint` on the new role and all modified task files.

**Relevant context:**
- Sub-task 1.3b runs whenever the component is not exposed, **including**
  when `ingress_domain` is cluster-local. Only the CoreDNS rewrites (1.4b)
  are skipped in that case.
- Partial exposure (e.g. `expose_peer: false`, `expose_ca: true`) works on
  the Service side. The CI per-endpoint-type rewrites of sub-task 1.4b,
  however, assume CA, peer and orderer are **all** unexposed, because the
  `-operations` suffix is shared by all three components. Mixed modes need
  exact per-FQDN rewrites and are out of scope for Step 1 CI.
- The port variables `ingress_grpc_peer_port`, `ingress_grpc_orderer_port`
  and `ingress_ca_port` from sub-task 1.1 remain Gateway-API listener ports
  for Step 2. They are **not** the native target ports above.

---

## Sub-task 1.4 — `run-tests.sh` variable injection for Step 1 flags

**Intent:** Extend the stabilized `run-tests.sh` (fixed in Step 0) to inject the newly introduced `INGRESS_TYPE` and `EXPOSE_*` variables into `tutorial/common-vars.yml`.

*(Note: Baseline fixes for positional argument crashes, `TEST_RUN_ID` stamping, and connection variable injection are implemented in [`MIGRATION-STEP-0.md`](./MIGRATION-STEP-0.md) Sub-task 0.2).*

**Expected outcomes:**
- `run-tests.sh` reads `INGRESS_TYPE` (default: `nginx`) and all `EXPOSE_*` flags from the environment (defaulting to safe values).
- `ingress_type` and `expose_*` flags are patched into `common-vars.yml` via `yq` prior to playbook execution.

**Todo list:**
- [ ] Update `.github/scripts/run-tests.sh` to include `yq` patching for `ingress_type` and the six `expose_*` boolean variables into `common-vars.yml`.
- [ ] Confirm that `INGRESS_TYPE`, `EXPOSE_CA`, `EXPOSE_PEER`, `EXPOSE_ORDERER`,
  `EXPOSE_PEER_OPERATIONS`, `EXPOSE_ORDERER_OPERATIONS`, and `EXPOSE_GRPCWEB`
  all default to safe values when not explicitly set.
- [ ] Verify `bash -n .github/scripts/run-tests.sh` passes syntax validation.

**Relevant context:**
- Baseline script: `.github/scripts/run-tests.sh` (as delivered in Step 0)
- Reference implementation: MIGRATION-PLAN.md §5.3.3
- Variable injection rationale (why `common-vars.yml` instead of `-e @file`):
  MIGRATION-PLAN.md §5.3.1 and the note following §5.3.3

---

## Sub-task 1.4b — CoreDNS per-endpoint-type rewrites for the `expose-none` CI leg

**Intent:** When `expose_*: false` with an external `ingress_domain` (CI:
`<ip>.nip.io` or `localho.st`), the existing CoreDNS wildcard rewrites
(`rewrite name regex (.*)\.<domain> host.ingress.internal`) send every
component FQDN to the nginx ClusterIP, which silently routes traffic through
nginx when the intent is to bypass it. This sub-task adds **one rewrite rule
per endpoint type** (`ca`, `peer`, `orderer`, `operations`, `grpcweb`,
`admin`). Each rule maps
`<ns>-<cr>-<endpoint>.<ingress_domain>` to the per-endpoint Service
`<ns>-<cr>-<endpoint>.<ns>.svc.<cluster_domain>` created by sub-task 1.3b.
Every endpoint therefore lands on its own native port: `-operations` reaches
9443/8443, `-grpcweb` reaches 7443 and `-admin` reaches 9443, never the API
port.

The dialled hostname stays the original FQDN, so TLS SANs remain valid and no
`csr_hosts` change or re-enrollment is needed.

**Cluster-local domain exception:** when `ingress_domain` is
`<namespace>.svc.<cluster_domain>`, the FQDNs are already the per-endpoint
Service FQDNs. No rewrite is applied.

**Design constraints:**
- The rules are applied by the CI bootstrap script
  (`.github/scripts/kind_with_nginx.sh`), **not by any Ansible role task**,
  consistent with MIGRATION-PLAN.md §1.1.
- They are written in `apply_coredns_override` at **cluster bootstrap,
  before any playbook runs**. The rules are patterns, so they do not depend
  on node names, and the console and the module health waits need them
  during `build_network.sh`.
- The existing `Corefile` content (the `localho.st` / nip.io wildcards to
  `host.ingress.internal`, the `hosts` block, the `kubernetes` plugin) is
  **kept**. The endpoint rules are inserted **before** the wildcards. With
  rewrite's default `stop` behaviour, the first matching rule wins, so
  endpoint FQDNs never reach the wildcard, while the console FQDN
  (`-console`, `-proxy`, matching no endpoint rule) still goes to nginx.
- `CLUSTER_DOMAIN` is not discovered: this function writes the `kubernetes`
  plugin line itself, so it uses the same `CLUSTER_DOMAIN` variable
  (default `cluster.local`) in both places.
- Each `name regex` rule has a matching `answer name` rule so that clients
  receive an answer for the name they asked for.

**Generated rule (one per endpoint type).** Example for namespace `default`,
ingress domain `127-0-0-1.nip.io` and endpoint type `operations`:

```
rewrite stop {
    name regex ^(default-[a-z0-9]+-operations)\.127-0-0-1\.nip\.io {1}.default.svc.cluster.local
    answer name ^(default-[a-z0-9]+-operations)\.default\.svc\.cluster\.local {1}.127-0-0-1.nip.io
}
```

`[a-z0-9]+` matches the operator CR name (assumption S1 in sub-task 1.3b: no
dashes). That prevents `default-org1peer-operations` from being confused with
a CR whose own name ends in an endpoint word.

**Expected outcomes:**
- In the `expose-none` leg, the CoreDNS ConfigMap contains six endpoint
  rewrite blocks ahead of the existing wildcards. In the `expose-all` leg, it
  is unchanged.
- From an in-cluster pod, `nslookup <ns>-<peer>-operations.<domain>` returns
  the ClusterIP of Service `<ns>-<peer>-operations`, which is neither the
  nginx ClusterIP nor the `<ns>-<peer>-peer` ClusterIP.
- The console FQDN still resolves to the nginx ClusterIP.
- CoreDNS is restarted after the ConfigMap is applied.
- The function is the direct prototype for the equivalent function in
  `kind_with_envoy_gateway.sh` introduced in Step 2.

**Todo list:**
- [ ] In `.github/scripts/kind_with_nginx.sh`, add the inputs (they default to
  the values the tutorial already uses):
  ```bash
  NAMESPACE=${NAMESPACE:-default}
  CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-cluster.local}
  # INGRESS_DOMAIN defaults to NIP_DOMAIN inside apply_coredns_override
  ```
- [ ] Add a helper that prints the endpoint rewrite blocks:
  ```bash
  # coredns_endpoint_rewrites NAMESPACE INGRESS_DOMAIN CLUSTER_DOMAIN
  # One rewrite per endpoint type: <ns>-<cr>-<endpoint>.<domain> -> per-endpoint
  # Service <ns>-<cr>-<endpoint>.<ns>.svc.<cluster_domain> (MIGRATION-STEP-1 1.3b).
  coredns_endpoint_rewrites() {
    local ns="$1" domain="$2" cluster_domain="$3"
    local domain_re="${domain//./\\.}"
    local cluster_domain_re="${cluster_domain//./\\.}"
    local endpoint
    for endpoint in ca peer orderer operations grpcweb admin; do
      printf '        rewrite stop {\n'
      printf '            name regex ^(%s-[a-z0-9]+-%s)\\.%s {1}.%s.svc.%s\n' \
        "${ns}" "${endpoint}" "${domain_re}" "${ns}" "${cluster_domain}"
      printf '            answer name ^(%s-[a-z0-9]+-%s)\\.%s\\.svc\\.%s {1}.%s\n' \
        "${ns}" "${endpoint}" "${ns}" "${cluster_domain_re}" "${domain}"
      printf '        }\n'
    done
  }
  ```
- [ ] In `apply_coredns_override`, compute the block only for a
  non-cluster-local `expose-none` run, and insert it right after `ready`,
  before the existing wildcard rewrites:
  ```bash
  INGRESS_DOMAIN=${INGRESS_DOMAIN:-${NIP_DOMAIN}}
  ENDPOINT_REWRITES=""
  if [[ "${EXPOSE_CA:-true}" == "false" \
     && "${EXPOSE_PEER:-true}" == "false" \
     && "${EXPOSE_ORDERER:-true}" == "false" \
     && "${INGRESS_DOMAIN}" != "${NAMESPACE}.svc.${CLUSTER_DOMAIN}" ]]; then
    ENDPOINT_REWRITES=$(coredns_endpoint_rewrites \
      "${NAMESPACE}" "${INGRESS_DOMAIN}" "${CLUSTER_DOMAIN}")
  fi
  ```
  ```
      .:53 {
          errors
          health {
             lameduck 5s
          }
          ready
  ${ENDPOINT_REWRITES}
          rewrite name regex (.*)\.localho\.st host.ingress.internal
          rewrite name regex (.*)\.${NIP_DOMAIN} host.ingress.internal
          hosts { ... unchanged ... }
          kubernetes ${CLUSTER_DOMAIN} in-addr.arpa ip6.arpa { ... unchanged ... }
          ...
  ```
- [ ] Make sure the `EXPOSE_*`, `NAMESPACE` and `INGRESS_DOMAIN` variables are
  exported **before** `kind_with_nginx.sh` runs in `fvtest.yml` (the matrix
  `env` of sub-task 1.5), because the script now runs before the playbooks.
- [ ] Run `bash -n .github/scripts/kind_with_nginx.sh`.
- [ ] Locally, run `kubectl -n kube-system get cm coredns -o yaml` after
  bootstrap with `EXPOSE_*=false` and check the six blocks and the unchanged
  wildcard / `hosts` lines.

**Relevant context:**
- Only CA, peer and orderer get endpoint rules. The console keeps resolving
  through the wildcard. With `expose_console: false`, the collection and the
  Job reach it through its in-cluster Service URL (sub-tasks 1.3 and 1.5),
  not through its FQDN.
- The rules are pattern-based, so they also cover nodes added later
  (`peers: N`, extra orderer nodes) without touching CoreDNS again.
- Partial exposure is not covered by these rules: see the last note of
  sub-task 1.3b.
- Sub-task 1.6 assertions 3–6 verify this end to end. When `INGRESS_DOMAIN`
  is cluster-local, assertion 6 is skipped (no rewrite to verify).

---

## Sub-task 1.5 — CI workflow: `expose-none` matrix leg with in-cluster Ansible runner

**Intent:** Extend `fvtest.yml` with a second matrix leg (`expose-none`) that
validates the extreme opposite scenario on the nginx path. Because the
`expose-none` leg routes every endpoint FQDN to a per-endpoint ClusterIP Service
through in-cluster CoreDNS rewrites (sub-tasks 1.3b and 1.4b), the GitHub
Actions runner — which is **outside** the KIND cluster — cannot resolve those
FQDNs: its `:443` traffic would still reach nginx through the KIND host-port
mapping, which is exactly the path this leg must not use.
The `expose-none` leg therefore runs the tutorial Ansible playbooks **from inside
the cluster** using a Kubernetes Job.

**Expected outcomes:**
- `fvtest.yml` runs two legs on every push:
  1. `expose-all` — all `expose_*: true`; playbooks run directly on the runner
     (current behaviour, no change to this path).
  2. `expose-none` — all `expose_*: false`; playbooks run inside the KIND
     cluster as a Kubernetes Job.
- `fail-fast: false` is set so both legs always complete.
- The `expose-none` leg succeeds: build, join, and deploy all exit 0.

**Job manifest specification:**

The Kubernetes Job YAML (committed to `.github/k8s/ansible-runner-job.yml` or
inlined in the CI script) must specify:

- **Container image**: an image containing Python 3, Ansible,
  `hyperledger.fabric_ansible_collection` (installed from the collection
  tarball built in the same CI run), the Hyperledger Fabric `peer` binary, and
  `configtxlator`. Use the same set of dependencies that the Actions runner
  installs for the `expose-all` leg. Base the image on
  `hyperledger/fabric-tools:<version>` and layer Ansible on top; document the
  resulting Dockerfile at `.github/docker/ansible-runner/Dockerfile`.
- **`restartPolicy: Never`** — failures surface as a failed Job rather than
  silent retries.
- **Tutorial files mount**: a `ConfigMap` (`tutorial-files`) created by a
  preceding CI step (`kubectl create configmap tutorial-files --from-file=tutorial/`)
  mounted at `/workspace/tutorial`.
- **`api_endpoint` override**: the in-cluster console Service URL
  `http://<console-svc>.<namespace>.svc.cluster.local:3000`.
- **Environment variables** injected for: `INGRESS_TYPE`, `EXPOSE_CA`,
  `EXPOSE_PEER`, `EXPOSE_ORDERER`, `EXPOSE_CONSOLE`, `WAIT_TIMEOUT`.
- **Job command** (with `set -e`):
  ```bash
  set -e
  cd /workspace/tutorial
  bash build_network.sh build
  bash join_network.sh join
  bash deploy_smart_contract.sh
  ```

**Todo list:**
- [ ] Add a `scenario` matrix dimension to the `fvtest` job in
  `.github/workflows/fvtest.yml` with values `[expose-all, expose-none]`.
  Set `fail-fast: false` on the matrix.
- [ ] For `expose-all`: set `EXPOSE_CONSOLE=true`, `EXPOSE_CA=true`,
  `EXPOSE_PEER=true`, `EXPOSE_ORDERER=true` in `$GITHUB_ENV`. Keep existing
  runner-side `run-tests.sh` invocation — this path is unchanged.
- [ ] For `expose-none`: set all four `EXPOSE_*` flags to `false` in
  `$GITHUB_ENV`. Keep `INGRESS_TYPE=nginx`.
- [ ] Create `.github/docker/ansible-runner/Dockerfile` based on
  `hyperledger/fabric-tools:<version>` with Ansible and
  `hyperledger.fabric_ansible_collection` layered on top.
- [ ] Add the following CI steps, each guarded by
  `if: matrix.scenario == 'expose-none'`:
  1. **Build and load runner image**: `docker build -t ansible-runner:ci
     .github/docker/ansible-runner/ && kind load docker-image ansible-runner:ci`
  2. **Create tutorial ConfigMap**:
     `kubectl create configmap tutorial-files --from-file=tutorial/`
  3. **Apply Job manifest**:
     `kubectl apply -f .github/k8s/ansible-runner-job.yml`
  4. **Wait for Job completion**:
     `kubectl wait --for=condition=complete --timeout=20m job/ansible-runner`
  5. **Retrieve logs** (unconditional, runs even on failure — use
     `if: always() && matrix.scenario == 'expose-none'`):
     `kubectl logs job/ansible-runner`
  6. **Assert Job succeeded**:
     ```bash
     phase=$(kubectl get job ansible-runner \
       -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
     [ "$phase" == "True" ] || exit 1
     ```
- [ ] Add `name: FV test (nginx / ${{ matrix.scenario }})` to the job.
- [ ] Run `yamllint` on the modified workflow file.
- [ ] Commit `.github/k8s/ansible-runner-job.yml` and
  `.github/docker/ansible-runner/Dockerfile` as part of this sub-task.

**Relevant context:**
- The `expose-all` leg is entirely unaffected by this sub-task — the `if:`
  conditions ensure the Job steps are skipped when `matrix.scenario == 'expose-all'`.
- The Job image must be available inside the KIND cluster (use
  `kind load docker-image` after building locally or in CI).
- Gateway API (`ingress_type: gateway-api`) matrix legs are **not** added in
  this step; leave a comment stub for Step 2.
- Reference full matrix design: MIGRATION-PLAN.md §5.3.4.

---

## Sub-task 1.6 — In-cluster service reachability assertions

**Intent:** Define explicit, automatable assertions for the `expose-none` CI leg
that verify in-cluster reachability without relying on the external runner's
network access. All assertions run as ephemeral pods via
`kubectl run --rm -i --restart=Never` and execute as a CI step **after** the
in-cluster Ansible Job from sub-task 1.5 completes.

**Expected outcomes:**
- Six named assertions all pass in the `expose-none` leg.
- The `expose-all` leg is unaffected (assertions are guarded by
  `if: matrix.scenario == 'expose-none'`).
- Any single failing assertion produces a clear, actionable error message
  identifying the misconfigured resource.

**Todo list:**

- [ ] **Assertion 1 — No external Ingress objects for CA/peer/orderer**
  (runner-side, no ephemeral pod needed):
  ```bash
  count=$(kubectl get ingress -n fabricinfra -o name \
    | grep -cvE 'console' || true)
  [ "$count" -eq 0 ] \
    || (echo "Unexpected Ingress objects found for non-console components" && exit 1)
  ```
  _Failure indicates_: an `expose_*` flag was not honoured by the operator, or
  the Ansible role created Ingress objects despite `expose_*: false`.

- [ ] **Assertion 2 — Console ClusterIP Service responds** at its in-cluster URL:
  ```bash
  kubectl run curl-console \
    --image=curlimages/curl:latest --restart=Never --rm -i \
    --namespace fabricinfra \
    -- curl -sf \
    http://<console-svc>.fabricinfra.svc.cluster.local:3000/ak/api/v3/health
  ```
  _Failure indicates_: the console pod is not running, the Service selector is
  wrong, or the health endpoint path has changed.

- [ ] **Assertions 3–6 — common preamble.** Endpoints are discovered from
  the labelled Services of sub-task 1.3b, so no node name is hardcoded:
  ```bash
  NS="${NAMESPACE:-default}"
  DOMAIN="${INGRESS_DOMAIN}"
  SEL=app.kubernetes.io/managed-by=fabric-ansible-collection
  svcs_of() {  # svcs_of <endpoint-type> -> Service names
    kubectl get svc -n "$NS" -l "$SEL,fabric-ansible-collection/endpoint=$1" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  }
  incluster() {  # incluster <name> <image> <cmd...>
    kubectl run "$1" --image="$2" --restart=Never --rm -i --quiet \
      --namespace "$NS" --command -- "${@:3}"
  }
  ```

- [ ] **Assertion 3 — One Service per endpoint, correct target port, ready
  backends.** Static check of the endpoint → port mapping table (sub-task
  1.3b). It proves that `-operations`, `-grpcweb` and `-admin` do not
  target the API port:
  ```bash
  declare -A want=( [ca/ca]=7054 [ca/operations]=9443
                    [peer/peer]=7051 [peer/operations]=9443 [peer/grpcweb]=7443
                    [orderer/orderer]=7050 [orderer/admin]=9443
                    [orderer/operations]=8443 [orderer/grpcweb]=7443 )
  for key in "${!want[@]}"; do
    comp="${key%/*}" ep="${key#*/}"
    names=$(kubectl get svc -n "$NS" \
      -l "$SEL,fabric-ansible-collection/component=$comp,fabric-ansible-collection/endpoint=$ep" \
      -o jsonpath='{.items[*].metadata.name}')
    [ -n "$names" ] || { echo "No $comp '$ep' Service found"; exit 1; }
    for svc in $names; do
      port=$(kubectl get svc -n "$NS" "$svc" -o jsonpath='{.spec.ports[?(@.port==443)].targetPort}')
      [ "$port" = "${want[$key]}" ] \
        || { echo "$svc: 443 -> $port, expected ${want[$key]}"; exit 1; }
      addrs=$(kubectl get endpoints -n "$NS" "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}')
      [ -n "$addrs" ] \
        || { echo "$svc has no ready backend (selector assumption S3?)"; exit 1; }
    done
  done
  ```
  The `orderer/admin` entry is expected only on Fabric ≥ 2.4.1 (operator
  gate). Drop it from `want` for older pinned versions.
  _Failure indicates_: sub-task 1.3b skipped a component or endpoint type, or
  used a wrong target port, or the selector (S3) matches no pod.

- [ ] **Assertion 4 — Every operations endpoint answers `/healthz` on `:443`
  through its FQDN.** This exercises CoreDNS rewrite + per-endpoint Service
  + port 9443/8443, the path used by the console status checks and the
  collection's health waits:
  ```bash
  urls=$(svcs_of operations | sed "s|.*|https://&.${DOMAIN}/healthz|")
  incluster healthz curlimages/curl:8.10.1 sh -c '
    for u in '"$(echo $urls)"'; do
      curl -sk --connect-timeout 5 "$u" | grep -q "\"status\":\"OK\"" \
        || { echo "FAIL $u"; exit 1; }
    done'
  ```
  _Failure indicates_: the `operations` rewrite is missing, the Service
  targets the API port, or the node is unhealthy.

- [ ] **Assertion 5 — API, CA, grpcweb and admin endpoints accept TLS on
  `:443` through their FQDNs.** The CA `-ca` endpoint must return `/cainfo`
  JSON. For gRPC, grpcweb and the mTLS-only admin endpoint, a TLS-level
  answer is enough: curl exit 0, 35 (handshake alert, e.g. a client
  certificate is required) or 56. Exits 6, 7 and 28 (DNS failure, connection
  refused, timeout) fail. Port correctness is already proven by assertion 3:
  ```bash
  ca_urls=$(svcs_of ca | sed "s|.*|https://&.${DOMAIN}/cainfo|")
  tls_urls=$(for ep in peer orderer grpcweb admin; do svcs_of "$ep"; done \
    | sed "s|.*|https://&.${DOMAIN}/|")
  incluster tls-check curlimages/curl:8.10.1 sh -c '
    for u in '"$(echo $ca_urls)"'; do
      curl -sk --connect-timeout 5 "$u" | grep -q caName || { echo "FAIL $u"; exit 1; }
    done
    for u in '"$(echo $tls_urls)"'; do
      rc=0; curl -sk -o /dev/null --connect-timeout 5 "$u" || rc=$?
      case $rc in 0|35|56) ;; *) echo "FAIL $u (curl exit $rc)"; exit 1;; esac
    done'
  ```
  _Failure indicates_: a rewrite for that endpoint type is missing, or the
  Service has no backend.

- [ ] **Assertion 6 — Each endpoint FQDN resolves to its own Service's
  ClusterIP** (not nginx, and not a sibling endpoint's Service). This
  confirms the sub-task 1.4b rewrites. Skipped when `INGRESS_DOMAIN` is
  cluster-local:
  ```bash
  pairs=$(kubectl get svc -n "$NS" -l "$SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.spec.clusterIP}{" "}{end}')
  incluster dns-check busybox:1.36.1 sh -c '
    for p in '"${pairs}"'; do
      fqdn="${p%%=*}.'"${DOMAIN}"'"; want="${p#*=}"
      got=$(nslookup "$fqdn" | awk "/^Address/ {a=\$2} END {print a}")
      [ "$got" = "$want" ] || { echo "FAIL $fqdn -> $got, expected $want"; exit 1; }
    done'
  ```
  _Failure indicates_: `coredns_endpoint_rewrites` was not emitted (check
  the `EXPOSE_*` / `INGRESS_DOMAIN` env passed to `kind_with_nginx.sh`), the
  `[a-z0-9]+` CR pattern does not match (assumption S1), or CoreDNS was not
  restarted.

- [ ] Add all six assertions as a single `"Verify expose-none reachability"` step
  in `fvtest.yml`, conditioned on `if: matrix.scenario == 'expose-none'`.
- [ ] Use `set -euo pipefail` at the top of the step's `run:` block so the
  first failing assertion aborts the step. Commands whose non-zero exit is
  expected are wrapped as `rc=0; cmd || rc=$?`.

**Relevant context:**
- Assertions 1–2 still use the placeholder values `fabricinfra` and
  `<console-svc>`. Replace them with `$NS` and the console Service name from
  the CI environment before committing.
- Assertions 3–6 cover **every** endpoint of **every** node, discovered from
  the `fabric-ansible-collection/*` labels. Adding peers or orderer nodes
  needs no change here.
- Sub-tasks 1.3b and 1.4b must be complete before assertions 3–6 can pass.

---

## Sub-task 1.7 — Tutorial: nginx expose-all scenario (no-regression)

**Intent:** Update or create a tutorial that explicitly demonstrates the
current default nginx deployment (all services exposed). This is a reference
baseline that confirms no regression and documents the `expose_*` variable schema
for users.

**Expected outcomes:**
- Tutorial page at `docs/source/tutorials/nginx-expose-all.rst` (new) or updated
  inline in `docs/source/tutorials/oss-installing.rst` with a dedicated section.
- Documents `ingress_type: nginx` (default), `expose_console: true`, and the
  other `expose_*: true` defaults.
- Shows how to set these variables in a vars file (e.g. `common-vars.yml`) or
  via `ansible-playbook -e @vars.yml`.
- Documents the existing `kubectl get ingress` verification steps.
- `make -C docs html` builds without warnings.

**Todo list:**
- [ ] Decide whether to add a new page or a section in the existing
  `oss-installing.rst`; document the decision in the plan file.
- [ ] Add a "Variables reference" table listing all `expose_*` and `ingress_type`
  variables with their defaults and effects (as specified in MIGRATION-PLAN.md §5.1).
- [ ] Add a verification step showing `kubectl get ingress -n <namespace>` output
  when all services are exposed.
- [ ] Run `make -C docs html` and fix any warnings.

**Relevant context:**
- Files to update: `docs/source/tutorials/oss-installing.rst`,
  `docs/source/tutorials/hlfsupport-installing.rst`.
- Role reference files: `docs/source/roles/fabric-operator-crds.rst`,
  `docs/source/roles/fabric-console.rst`.

---

## Sub-task 1.8 — Tutorial: nginx no-expose scenario

**Intent:** Create a new tutorial that demonstrates the extreme opposite scenario:
deploying a Hyperledger Fabric network on a single cluster where no service is
exposed externally through the NGINX ingress controller. This is the canonical
Scenario A (in-cluster only) tutorial.

**Expected outcomes:**
- New tutorial page at
  `docs/source/tutorials/nginx-no-expose.rst`.
- Demonstrates setting `expose_console: false`, `expose_ca: false`,
  `expose_peer: false`, `expose_orderer: false` in a vars file.
- Explains that the collection will health-check the console via its in-cluster
  ClusterIP Service URL and print a notice instead of a public URL.
- Explains that Fabric components communicate via ClusterIP Services inside the
  cluster.
- Shows that `kubectl get ingress -n <namespace>` returns no resources.
- Added to the `toctree` in `docs/source/index.rst`.
- `make -C docs html` builds without warnings.

**Todo list:**
- [ ] Create `docs/source/tutorials/nginx-no-expose.rst` with:
  - Prerequisites section (nginx ingress controller installed but routes not
    required for in-cluster use).
  - Example vars file showing all `expose_*: false` and `ingress_type: nginx`.
  - Step-by-step playbook execution using `ansible-playbook -e @no-expose-vars.yml`.
  - Verification: `kubectl get ingress` returns empty; console notice message
    appears in playbook output.
  - Explanation of when to use this scenario (single-cluster bootstrap, GitOps
    lead-org setup, development environment).
- [ ] Add `nginx-no-expose` to the `toctree` in `docs/source/index.rst`.
- [ ] Run `make -C docs html` and fix any warnings.

**Relevant context:**
- Scenario A rationale: PRE-ANALYSIS.md §2.4 and §2.5.
- Console notice message implementation: sub-task 1.3 above.
- In-cluster console URL: `http://{{ console }}.{{ namespace }}.svc.cluster.local:3000`

---

## Acceptance criteria for Step 1

A Step 1 delivery is considered complete when all of the following pass:

1. `ansible-lint` and `yamllint` pass on all modified files.
2. `run-tests.sh` correctly injects all `ingress_type` and `expose_*` variables into `common-vars.yml` (and passes `bash -n` validation).
3. `fvtest.yml` matrix runs two legs: `nginx/expose-all` and
   `nginx/expose-none`; both complete successfully with `fail-fast: false`.
4. The `nginx/expose-all` leg is byte-for-byte equivalent in test coverage to
   the pre-Step-1 single-leg run — no existing test scenario has been removed
   or weakened.
5. The `nginx/expose-none` leg runs the tutorial playbooks inside the KIND
   cluster via a Kubernetes Job (sub-task 1.5) and all six reachability
   assertions pass (sub-task 1.6): no Ingress objects for CA/peer/orderer;
   console health endpoint returns HTTP 200 in-cluster; one Service per
   endpoint exists with the expected `443 → targetPort` and ready backends;
   every operations FQDN answers `/healthz` on `:443`; every API, CA, grpcweb
   and admin FQDN accepts TLS on `:443`; each endpoint FQDN resolves to its
   own Service's ClusterIP.
6. In `expose-none` mode the collection creates **one ClusterIP Service per
   endpoint** (CA: `ca`, `operations`; peer: `peer`, `operations`, `grpcweb`;
   orderer: `orderer`, `admin`, `operations`, `grpcweb`), each mapping `443`
   to that endpoint's native port (sub-task 1.3b), with **one CoreDNS rewrite
   per endpoint type** (sub-task 1.4b). The operator's own Services are left
   unmodified, and console registry entries are not mutated.
7. Cluster-local domain handling (sub-tasks 1.1 and 1.1b):
   - Setting `ingress_domain: <namespace>.svc.<cluster_domain>` with all
     `expose_*: false` runs without error: the per-endpoint Services are
     created and no CoreDNS rewrite is applied.
   - Setting `ingress_domain: <namespace>.svc.<cluster_domain>` with any
     `expose_*: true` causes the play to fail immediately with a message listing
     the conflicting flags.
   - Setting any other `*.<cluster_domain>` value (e.g. `svc.cluster.local`)
     fails immediately, naming the only supported form.
   - The cluster domain is always looked up, best effort, in the
     `kube-system/coredns` ConfigMap via `k8s_info` (no `kubectl exec`).
     When found, it is used if `cluster_domain` is empty, and a different
     user-set `cluster_domain` fails the play naming both values. When not
     found, a user-set `cluster_domain` is trusted with a warning, and an
     empty one fails the play asking the user to set it.
8. `docs/source` builds without warnings (`make -C docs html`).
9. No Gateway API CRD, template, task, or Kubernetes resource is introduced —
   the Gateway API path is entirely absent from the codebase at this stage.

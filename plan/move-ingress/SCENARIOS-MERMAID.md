# Step 1 — Scenarios A, B and C

Diagrams of the three scenarios handled by
[`MIGRATION-STEP-1.md`](./MIGRATION-STEP-1.md#scenarios) (design:
[`URL-MANAGEMENT-NEW.md`](./URL-MANAGEMENT-NEW.md) §4). Names are those of
the local KIND test cluster: namespace `default`, console `hlf-console`, one
peer `org1peer`.

<a id="scenario-a"></a>
## Scenario A — everything exposed (default)

```mermaid
flowchart LR
  subgraph out["Outside the cluster"]
    web["Browser"]
    ans["Ansible on a laptop<br/>or the CI runner"]
  end
  subgraph kind["KIND cluster, namespace default"]
    nginx["nginx Ingress controller<br/>port 443, SSL passthrough"]
    ingC["console Ingress<br/>class nginx"]
    ingP["org1peer Ingress<br/>class nginx, one host per endpoint"]
    console["console pod<br/>port 3000"]
    peer["peer pod<br/>7051 api, 9443 operations, 7443 grpcweb"]
    dns["CoreDNS<br/>wildcard: *.127-0-0-1.nip.io to nginx"]
  end
  web -->|"default-hlf-console-console.127-0-0-1.nip.io"| nginx
  ans -->|"console REST API and node health waits<br/>*.127-0-0-1.nip.io = 127.0.0.1, host port 443"| nginx
  nginx --> ingC --> console
  nginx --> ingP --> peer
  console -.->|"status checks<br/>default-org1peer-operations.127-0-0-1.nip.io"| dns
  dns -.-> nginx
```

<a id="scenario-b"></a>
## Scenario B — nothing exposed, cluster-local HLF domain (Step 1 target)

```mermaid
flowchart LR
  subgraph out["Outside the cluster"]
    web["Browser"]
  end
  subgraph kind["KIND cluster, namespace default"]
    job["ansible-runner Job<br/>runs run-tests.sh (1.9)"]
    svcC["Service hlf-console<br/>port 3000, created by the operator"]
    console["console pod<br/>networkinfo.domain example.com<br/>deployer.domain default.svc.cluster.local"]
    dns["CoreDNS<br/>no rewrite, plain Service lookup"]
    sP["Service default-org1peer-peer<br/>443 to 7051"]
    sO["Service default-org1peer-operations<br/>443 to 9443"]
    sW["Service default-org1peer-grpcweb<br/>443 to 7443"]
    peer["peer pod"]
    nginx["nginx Ingress controller"]
    ingC["console Ingress<br/>class none (1.5)"]
  end
  job -->|"hlf-console.default.svc.cluster.local:3000<br/>HTTPS"| svcC --> console
  job -->|"module health waits"| dns
  console -->|"status checks, grpcweb proxy"| dns
  dns -->|"default-org1peer-peer.default.svc.cluster.local"| sP
  dns -->|"default-org1peer-operations.default.svc.cluster.local"| sO
  dns -->|"default-org1peer-grpcweb.default.svc.cluster.local"| sW
  sP --> peer
  sO --> peer
  sW --> peer
  web -.->|"default-hlf-console-console.example.com<br/>no DNS record yet, 404 if forced"| nginx
  nginx -.->|"class none: ignored"| ingC
```

<a id="scenario-c"></a>
## Scenario C — nothing exposed, previous FQDNs

```mermaid
flowchart LR
  subgraph kind["KIND cluster, namespace default"]
    job["ansible-runner Job<br/>runs run-tests.sh (1.9)"]
    svcC["Service hlf-console<br/>port 3000"]
    console["console pod<br/>networkinfo.domain 127-0-0-1.nip.io<br/>no deployer.domain"]
    dns["CoreDNS<br/>6 endpoint rewrites (1.8)<br/>then the nip.io wildcard"]
    sP["Service default-org1peer-peer<br/>443 to 7051"]
    sO["Service default-org1peer-operations<br/>443 to 9443"]
    sW["Service default-org1peer-grpcweb<br/>443 to 7443"]
    peer["peer pod"]
    nginx["nginx Ingress controller"]
  end
  job -->|"hlf-console.default.svc.cluster.local:3000<br/>HTTPS"| svcC --> console
  job -->|"default-org1peer-*.127-0-0-1.nip.io"| dns
  console -->|"default-org1peer-*.127-0-0-1.nip.io"| dns
  dns -->|"peer rule"| sP
  dns -->|"operations rule"| sO
  dns -->|"grpcweb rule"| sW
  sP --> peer
  sO --> peer
  sW --> peer
  dns -.->|"default-hlf-console-console.127-0-0-1.nip.io<br/>wildcard: nginx, console Ingress class none"| nginx
```

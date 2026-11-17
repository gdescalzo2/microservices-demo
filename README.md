# Online Boutique as a platform service — L2 Challenge

A fork of [GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo) (Online Boutique), taken to a level where it can be released, operated and demoed on Kubernetes:
- two environments (dev/prod) and GitOps with Argo CD
- Gateway API and observability with Prometheus/Grafana
- baseline security: Secrets, RBAC, Pod Security, NetworkPolicy, Kyverno
- a runbook and reproducible failure scenarios
- a Krateo PoC that exposes the service as self-service

The original project README is in [README.upstream.md](README.upstream.md).

| Document | Content |
|---|---|
| [docs/challenge/architecture.md](docs/challenge/architecture.md) | Application and platform architecture, flows, choices and trade-offs |
| [docs/challenge/runbook.md](docs/challenge/runbook.md) | Verification, symptom-based troubleshooting, rollback |
| [docs/challenge/security.md](docs/challenge/security.md) | Secrets, RBAC, policies, supply chain, residual limits |
| [docs/challenge/krateo.md](docs/challenge/krateo.md) | Krateo evaluation, blueprint and PoC |
| [docs/challenge/ai-usage.md](docs/challenge/ai-usage.md) | How AI was used, what was verified and what was rejected |
| [docs/challenge/demo.md](docs/challenge/demo.md) | End-to-end demo script (the 11 required steps) |

---

## 1. Why Online Boutique

**Domain.** A demo e-commerce site with a catalog, cart and currency conversion. Checkout runs with simulated payment and shipping, and sends a confirmation email. The site also shows recommendations and ads. A load generator (Locust) simulates users.

**Why it fits an L2 challenge:**

| Criterion | Online Boutique |
|---|---|
| Complexity | 11 microservices + Redis, 5 languages (Go, C#, Node.js, Python, Java) |
| Cloud-native relevance | Built for Kubernetes, gRPC internally, HTTP frontend, stateless services plus one stateful component |
| Available manifests | Kustomize base + components, Helm chart, "release" manifests |
| Observability | Structured JSON logs and gRPC/HTTP probes already in place; **no Prometheus metrics** (gap filled here) |
| Demo suitability | Visible UI, end-to-end purchase flow testable with curl, load generated automatically |
| Realistic failure scenarios | Long dependency chain (checkout calls 6 services): a fault deep down shows up as a symptom at the surface, ideal for troubleshooting |

Alternatives considered:
- *Sock Shop* (Weaveworks): no longer maintained.
- *OpenTelemetry Demo*: richer on observability, but about twice the components, too heavy for a 10 GB VM.

**Parts used in the challenge:**
- every service in the upstream Kustomize base (`kustomize/base`)
- the upstream `network-policies` component
- the **frontend** code, modified

Not used:
- `shoppingassistantservice`, which needs Gemini/AlloyDB on GCP
- the GCP components (Spanner, Memorystore, Cloud Operations)
- Terraform and the Istio manifests

## 2. What was added or changed compared to upstream

| Area | Change | Where |
|---|---|---|
| Code | Frontend: Prometheus metrics on a dedicated port `9090` (requests by route/code, latency histogram, `build_info` with version), `X-App-Version` header, version injected at build time. Unit tests. | `src/frontend/metrics.go`, `metrics_test.go`, `main.go`, `Dockerfile` |
| Packaging | Platform base on top of the upstream Kustomize + `dev`/`prod` overlays + components | `platform/deploy/` |
| Exposure | Gateway API (shared Gateway + one HTTPRoute per environment) instead of the LoadBalancer Service | `platform/addons/config/gateway/`, `overlays/*/httproute.yaml` |
| Security | Redis password from a Secret (not in Git), dedicated ServiceAccount for Redis too, no API tokens mounted, seccomp, PSA `restricted`, per-persona RBAC, Kyverno policies | `platform/deploy/base/patches/`, `overlays/*/rbac.yaml`, `platform/addons/config/policies/` |
| GitOps | Argo CD: AppProjects with guardrails, 3 Applications (platform-config, dev, prod) | `platform/gitops/` |
| Observability | ServiceMonitor, 8 alert rules linked to the runbook, Grafana dashboard | `platform/deploy/components/observability/`, `platform/addons/config/monitoring/` |
| CI | Lint, render + schema validation, "no Secrets in Git" guard, Go tests, image build + Trivy, push to GHCR. Actions pinned to SHAs. | `.github/workflows/platform-ci.yaml` |
| Operations | Idempotent bootstrap, end-to-end smoke test, GitOps release/rollback, failure scenarios, RBAC check | `platform/scripts/` |
| Krateo | Golden-path chart with `values.schema.json`, CompositionDefinition, PoC with core-provider | `platform/krateo/`, `platform/scripts/krateo-poc.sh` |
| Cleanup | Removed the upstream workflows that need Google's GCP project (`ci-main`, `ci-pr`, `deploy-pr`, `cleanup`, `make-release`) | `.github/workflows/` |

The whole diff against upstream sits in four places:
- `platform/`
- `docs/challenge/`
- `src/frontend/` (4 files)
- `.github/workflows/`

See it with `git diff upstream/main --stat`.

## 3. Repository layout (new parts)

```
platform/
├── kind/cluster.yaml                 # local cluster (single node)
├── deploy/
│   ├── base/                         # = upstream kustomize/base + platform patches
│   ├── components/
│   │   ├── kind-sizing/              # reduced CPU requests for a laptop
│   │   └── observability/            # ServiceMonitor
│   └── overlays/{dev,prod}/          # namespace, HTTPRoute, RBAC, HPA/PDB (prod), frontend version
├── addons/
│   ├── values/                       # Helm values: metrics-server, kube-prometheus-stack, kyverno, argo-cd
│   └── config/                       # Gateway, alerts, dashboard, policies (synced by Argo CD)
├── gitops/                           # Argo CD AppProjects + Applications
├── krateo/                           # golden path: chart + CompositionDefinition + examples
└── scripts/                          # bootstrap, build, smoke test, release, rollback, chaos, rbac, krateo
docs/challenge/                       # challenge documentation
```

## 4. Prerequisites

A Linux VM or host with **4 vCPU, 10 GB RAM, 60 GB disk**. The reference setup is Ubuntu 26.04 LTS on VMware Workstation.

1. **Docker Engine** (not Docker Desktop):
   ```bash
   # official Docker repository (https://docs.docker.com/engine/install/ubuntu/);
   # if it does not support your Ubuntu release yet: sudo apt install docker.io
   sudo usermod -aG docker "$USER"   # then log out and back in
   ```
2. **inotify limits** (otherwise kind fails with "too many open files"):
   ```bash
   echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512" | sudo tee /etc/sysctl.d/99-kind.conf
   sudo sysctl --system
   ```
3. **Utilities**: `sudo apt install -y git curl jq openssl`
4. **CLIs** (kind, kubectl, helm, kustomize, kubeconform, argocd, k9s) in `~/.local/bin`, no sudo:
   ```bash
   platform/scripts/install-tools.sh
   ```
5. A **public fork** of this repository on GitHub: Argo CD reads from it.

## 5. Installation

```bash
git clone https://github.com/<your-user>/microservices-demo.git && cd microservices-demo
platform/scripts/set-github-user.sh <your-user>    # replaces the YOUR_GITHUB_USER placeholder
git commit -am "chore: point platform to my fork" && git push
platform/scripts/bootstrap.sh          # 15-25 minutes the first time (image downloads)
```

`bootstrap.sh` is idempotent. In order, it:
1. creates the kind cluster and starts cloud-provider-kind (LoadBalancer + Gateway API);
2. installs metrics-server, kube-prometheus-stack, Kyverno and Argo CD with Helm;
3. builds and loads the frontend image;
4. generates the Redis Secrets;
5. registers the Argo CD Applications;
6. adds the `/etc/hosts` entries (after asking).

From then on, **Git drives the cluster**.

> Helm chart versions are not pinned (the latest stable is installed). After the first successful run, pin them with `KPS_VERSION`, `KYVERNO_VERSION`, `ARGOCD_VERSION` and `METRICS_SERVER_VERSION` for reproducibility (`helm list -A` shows the installed ones).

## 6. Verification and tests

```bash
platform/scripts/smoke-test.sh dev     # home, product, cart, checkout, health, version, metrics
platform/scripts/smoke-test.sh prod
platform/scripts/rbac-check.sh         # per-persona permission matrix (impersonation)
```

| What | How |
|---|---|
| Shop | http://dev.boutique.local, http://boutique.local |
| Argo CD | `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080 |
| Grafana | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` → dashboard "Online Boutique - Overview" |
| Prometheus | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → `/alerts` |

## 7. Common operations

```bash
platform/scripts/release.sh dev 1.1.0            # build + commit the tag + Argo CD sync + rollout
SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0   # promote the same image to prod
platform/scripts/rollback.sh prod                # git revert of the last overlay change
platform/scripts/rollback.sh dev --emergency     # kubectl rollout undo (without Git)
platform/scripts/chaos.sh list                   # failure scenarios
platform/scripts/create-secrets.sh --rotate      # rotate the Redis password
platform/scripts/teardown.sh                     # remove everything
```

Details and diagnosis in the [runbook](docs/challenge/runbook.md).

## 8. CI pipeline

`.github/workflows/platform-ci.yaml` runs on pushes and PRs that touch `platform/`, `src/frontend/` or `kustomize/`:

1. **validate**: shellcheck, yamllint, render of the overlays and the Krateo chart, `kubeconform -strict` with CRD schemas (Gateway API, Argo CD, Prometheus Operator, Kyverno), check that no Secret ends up in Git.
2. **frontend**: `gofmt`, `go vet`, `go test -race`.
3. **image**: build, Trivy scan (blocks on CRITICAL CVEs that have a fix available), push to `ghcr.io/<owner>/boutique-frontend` from `main` only.

CI **does not deploy** and holds no cluster credentials: Argo CD pulls from Git.

## 9. Known limits

- Environments are simulated with namespaces on the same cluster: no node or control-plane isolation.
- Redis uses `emptyDir`: the cart is lost when the pod restarts (as upstream).
- Secrets are generated by a script and are not reconciled by GitOps. In production use External Secrets or Sealed Secrets ([security](docs/challenge/security.md)).
- Application metrics cover only the frontend. Other services expose only probes and logs. OpenTelemetry tracing is supported upstream but not enabled.
- CPU requests are lowered to fit two environments on 4 vCPU (`kind-sizing`). In production this would be a capacity-planning mistake ([architecture](docs/challenge/architecture.md#capacity)).

# Use of AI in the challenge

This document states transparently:
- **who did what**;
- **what was verified, and how**;
- **where the AI got it wrong**.

The mistakes are the most useful part. They show why every output went through a check before entering the repository.

## 1. Tools and way of working

| Tool | Where | What for |
|---|---|---|
| **Claude (Opus 5.5) in agent mode** on claude.ai | Remote Linux workspace with shell, git, Go, kustomize, kubeconform, shellcheck, web search | Analysis of the upstream repository, design, writing manifests, scripts, pipeline and documentation, static validation |
| **Claude Code** in the Ubuntu VM terminal | Local VM with Docker and kind | Real execution: bootstrap, demo, troubleshooting on the live cluster, fixes |

**Division of roles.**
- **I** provided the challenge text, the constraints (VM with 4 vCPU and 10 GB, same-day delivery, English documentation, speed not a concern) and the direction-setting decisions. I reviewed the outputs, then ran and verified them on the cluster.
- **The agent** did the analysis, the implementation and the first validation.

**Technical responsibility for what is in the repository stays with me.** Every file was read, and everything that can be run was run. §6 lists what still has to be verified live.

**A constraint found at the start, and how it was handled.** The agent's workspace cannot reach container registries (Docker Hub, GCR, registry.k8s.io), so it cannot start a cluster. Instead of "faking" a test, the work was split:
- **static validation in the workspace**: Kustomize render, `kubeconform -strict` with CRD schemas, shellcheck, yamllint, `go test` on the new code, JSON Schema validation;
- **dynamic validation in the VM**: bootstrap, smoke tests, failure scenarios.

## 2. By area

### 2.1 Initial analysis

| Problem | Approach | Result | Verification |
|---|---|---|---|
| Understand the app quickly (11 services, 5 languages) | The agent cloned upstream and read **the manifests and the code**, not just the README: `kustomize/base`, `helm-chart/values.yaml`, `src/frontend/main.go`, `src/cartservice/Startup.cs`, `src/checkoutservice/main.go` | Map of services, ports, dependencies (from the `*_SERVICE_ADDR` variables), probes, securityContext | The tables in architecture.md were derived from the files, not from the model's memory |
| Find the gaps against the requirements | Requirement-by-requirement comparison | No Prometheus metrics in any service (`initStats()` is a TODO); Redis without authentication; Redis on the `default` SA; mutable `redis:alpine` tag; public LoadBalancer Service; no seccomp | `grep -r prometheus src/` → empty; manifests read |
| Error semantics in checkout | Reading `PlaceOrder` | **Correction of a first wrong claim**: the agent had written that an email failure blocks the order. The code shows that email and `EmptyCart` errors are only logged | `src/checkoutservice/main.go` lines 263–276 |

### 2.2 Implementation

| Area | Where AI sped things up | Where it had to be corrected or rewritten |
|---|---|---|
| Kustomize base/overlays | Structure, hardening patches, RBAC, HPA/PDB in a few minutes | JSON patch with the wrong index (§3.3); HPA/replicas conflict (§3.4); undeclared replicas (§3.5) |
| Frontend metrics (Go) | Middleware + Prometheus exposition + tests | A deliberate choice of the stdlib over `client_golang`. `go.sum` could not be updated in the workspace (Go proxy blocked), and an unverifiable `go.sum` does not go into the repo. Trade-off documented |
| Operational scripts | Idempotent bootstrap, smoke test, release/rollback, chaos | `grep -q` + `pipefail` bug (§3.6); shellcheck reported 3 warnings, fixed |
| CI pipeline | Job structure | SHA pinning resolved with `git ls-remote`; one SHA written from memory was wrong (§3.2) |
| Kyverno policies | The 4 policies | The first version of `disallow-latest-tag` used `foreach/deny` with a wildcard in an `Equals` operator (semantics not guaranteed). Rewritten with the documented pattern `"*:* & !*:latest"` |
| Krateo | Chart + schema + PoC script | The naming rule of the generated CRD was verified **in the core-provider source** instead of inferred |

### 2.3 Operations and troubleshooting

While writing, the AI built the diagnostic tooling:
- a symptom-based runbook;
- alerts linked to the runbook;
- reproducible failure scenarios.

The real troubleshooting case with AI on the live cluster is in **§4**, to be filled in during the run in the VM.

### 2.4 Documentation

The agent generated drafts from the real repository files. Every command in the documents maps to an existing file or script. Runtime-dependent details (output, timings) must be confirmed in the VM (§6). The documentation was first written in Italian and then translated into English after a change of requirements. The translation went through the same check that every command and path still matches the repository.

## 3. AI mistakes caught by verification

Concrete examples, each with *how* it surfaced.

**3.1 Outdated knowledge: ingress-nginx.**
- *What happened*: the natural first choice to expose the service on kind was ingress-nginx. A search done *before* writing the manifests showed that the project was **retired in March 2026** (no more security patches).
- *Fix*: **Gateway API**, implemented locally by cloud-provider-kind.
- *Lesson*: for anything about the "current state" (versions, projects, best practices), the model must be checked against up-to-date sources.

**3.2 A GitHub Action SHA written from memory.**
- *What happened*: every action is pinned to a SHA, a choice motivated by the March 2026 `trivy-action` incident (CVE-2026-33634, rewritten tags). For `actions/upload-artifact` the agent first wrote a "remembered" SHA and version (v4.6.2). A check with `git ls-remote` showed the latest version is v7.0.2, with a different SHA.
- *Lesson*: cryptographic identifiers and versions **are not generated, they are resolved**.

**3.3 JSON patch with the wrong index.**
- *What happened*: to set the load generator's `USERS`, the agent used `op: replace` on `/env/2/value`. The rendered output showed that index 2 was **`RATE`**, not `USERS`: the patch silently changed the wrong variable.
- *Fix*: a strategic merge patch that selects the variable by name.
- *Lesson*: check the rendered output, not just that the build "passes".

**3.4 HPA and replicas in conflict.**
- *What happened*: the first version of the prod overlay declared `replicas: 2` on the frontend *and* an HPA. With Argo CD self-heal, the two controllers would keep overwriting each other.
- *Fix*: `replicas` removed; the HPA owns the replica count.

**3.5 Drift invisible to Argo CD.**
- *What happened*: in the `redis-down` scenario (`scale --replicas=0`), restoring via sync would not have worked. Upstream **does not declare `replicas`**, and Argo CD can only detect drift on fields that exist in Git.
- *Fix*: explicit replicas added in the base, except for the frontend (see 3.4).

**3.6 False negative in the smoke test.**
- *What happened*: `curl … | grep -q` with `set -o pipefail`. `grep -q` exits at the first match, curl gets SIGPIPE, and the pipeline fails **even though the text is there**.
- *Fix*: replaced with `grep >/dev/null`.

**3.7 HPA with a reduced request.**
- *What happened*: the `kind-sizing` component sets CPU requests to 20m. For the prod frontend HPA, utilization would always look very high, so it would always scale to the maximum.
- *Fix*: the frontend request in prod is set back to 100m.

## 4. Troubleshooting case with AI

> To be filled in during the run in the VM with Claude Code. Recommended scenario: `chaos.sh netpol-typo dev`. It is the most instructive one, because every pod stays `Ready` and only checkout fails.

| | |
|---|---|
| **Observed symptom** | _(e.g. failed order, BoutiqueCheckoutFailing alert)_ |
| **Input given to the AI** | _(output of `get pods`, frontend and checkout logs, events; never Secrets)_ |
| **Prompt** | _see below_ |
| **Proposed hypotheses** | _(list, ordered by likelihood)_ |
| **Proposed verification commands** | _(which were run, which were rejected and why)_ |
| **Root cause identified** | _ |
| **Fix** | _(through Git or sync, not kubectl edit)_ |
| **Verification** | _(smoke test, metric back to 0, alert resolved)_ |
| **Value** | _(time to diagnosis; what I would have done without AI)_ |

A template prompt that keeps the AI to diagnosis:

```text
You are supporting an L2 operator. Context: Online Boutique on kind, namespace boutique-dev,
Argo CD with self-heal disabled in dev. Symptom: <...>. Attached output of: <commands>.
1) List at most 3 hypotheses ordered by likelihood, with the evidence supporting each.
2) For each one, the read-only command that confirms or rules it out.
3) Do not propose changes until a hypothesis is confirmed. Fixes must go through Git.
```

## 5. Personal AI governance

| Rule | How it was applied |
|---|---|
| **No secrets in prompts** | The Redis password is generated *in the cluster* by `openssl rand` and never printed or pasted. Troubleshooting prompts get logs and events, never `get secret -o yaml` |
| **Destructive commands only when understood** | The scripts always use `--context kind-boutique` (no risk of acting on the wrong cluster); teardown and chaos in prod ask for confirmation; in prod no `kubectl edit`, only Git |
| **Validate before running** | Manifests → `kustomize build` + `kubeconform -strict`; scripts → `shellcheck` + `bash -n`; Go → `go vet` + `go test -race`; Krateo schema → `jsonschema` with valid and invalid inputs |
| **Plausible ≠ working** | Anything not executed is listed in §6 and not presented as tested |
| **Sources for the current state** | ingress-nginx retirement, the Trivy incident and the Krateo APIs were checked against up-to-date web sources or the source code |
| **Identifiers resolved, not generated** | Action SHAs via `git ls-remote`; Krateo GVK from the source |
| **Small, readable diffs** | Upstream untouched except 4 frontend files; everything else in `platform/` and `docs/challenge/` |

## 6. Checks still to run on the cluster

An honest list of what static validation cannot guarantee. Tick them during the first bootstrap in the VM:

- [ ] Full `go build` of the frontend (toolchain 1.27, not available in the agent's workspace); the new code is tested in isolation
- [ ] cloud-provider-kind: Gateway gets an address and routes by host; whether the `exclude-from-external-load-balancers` label must be removed from the single node
- [ ] kindnet actually enforces NetworkPolicies (default deny + `netpol-typo`)
- [ ] Redis with `--requirepass $(REDIS_PASSWORD)` and cartservice with a `password=` connection string work
- [ ] Kyverno policies: the `"*:* & !*:latest"` syntax, per-rule `failureAction`, no false positives on the workloads
- [ ] PSA `restricted` admits every pod (including the load generator's init container)
- [ ] kube-prometheus-stack, Kyverno and Argo CD values with the current chart versions
- [ ] Dashboard panels and alerts with real data
- [ ] `helm lint`/`helm template` of the Krateo chart; PoC: CDC permissions to create Applications in `argocd`
- [ ] Real bootstrap duration and memory usage (estimate: 6–7 GB)

## 7. Value delivered and limits

**Value**: in about a day, a complete and consistent platform:
- packaging for 2 environments and GitOps;
- observability and security;
- CI, runbook and failure scenarios;
- the Krateo PoC.

Without AI this would have taken several days. The biggest gains were in reading a polyglot codebase quickly, writing repetitive YAML and scripts, and documentation. The AI also brought up points that might otherwise have been missed, such as SHA pinning after the Trivy incident and the retirement of ingress-nginx. That was useful only because they were verified.

**Limits observed**:
- outdated knowledge of versions and project status (§3.1, §3.2);
- "plausible" mistakes that pass syntax validation (§3.3, §3.6): only inspecting the output or running the code reveals them;
- a tendency to make claims about code behavior without reading the code (§2.1, checkout). Mitigation: always ask for the line of code or the command that confirms the claim.

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
| Kyverno policies | The 4 policies | The first version of `disallow-latest-tag` used `foreach/deny` with a wildcard in an `Equals` operator (semantics not guaranteed). Rewritten with the documented pattern `"*:* & !*:latest"`. On the first real cluster, Kyverno 1.20 refused every legacy `ClusterPolicy`: all 4 policies migrated to CEL `ValidatingPolicy` (§3.11) |
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

**3.8 First CI run: two failures that static validation could not catch.**
- *What happened*: the first push to the fork ran the pipeline, and two jobs failed. (1) The runner's shellcheck flagged SC2015 (`A && B || C` is not if-then-else) in two scripts; the local shellcheck 0.11 had not. (2) `go vet` failed with `copylocks` findings: all of them in **upstream** code (`handlers.go`, `money/`), where protobuf `Money` values are passed by value.
- *Diagnosis*: read `gh run view --log-failed` before changing anything; checked that none of the vet findings pointed to files changed by the challenge. The fact that vet reached the analysis stage also proved that the modified frontend compiles with Go 1.27.
- *Fix*: the two shell lines rewritten as explicit `if` statements; `go vet -copylocks=false` with a comment explaining why (the upstream code is left untouched); yamllint and shellcheck pinned in CI to the versions used for local validation. Second run: all three jobs green; image pushed to GHCR; Trivy found no fixable CRITICAL CVEs and 6 HIGH ones (reported, not blocking by design).
- *Lesson*: "passes locally" is only as good as the parity between local and CI tooling. Pin linter versions.

The next entries come from the **first real bootstrap** in the VM (Ubuntu 26.04, 4 vCPU, 9.2 GiB, kind v0.33 / Kubernetes v1.37, Helm v4.3). Each one passed every static check.

**3.9 Grafana stuck in a liveness loop: a memory limit estimated without data.**
- *What happened*: `helm --wait` failed on kube-prometheus-stack with `Progress deadline exceeded`. Grafana (chart 93.3.1, Grafana 13) was killed by its liveness probe every ~3 minutes (exit 137, `Reason: Error`, not `OOMKilled`).
- *Diagnosis*: hypotheses ordered (slow image pull → crash from values → volume), read-only checks only. The image had pulled fine; logs showed Grafana still initialising when killed; `kubectl top --containers` showed **250Mi against a 256Mi limit and 2.2 CPU**: a Go process pinned to its memory limit, most likely GC pressure (an inference from the two measurements, not profiled). Grafana 13 also registers ~20 bundled plugins (~45 s) and runs most datasources as separate backend processes.
- *Fix*: memory 256Mi/640Mi and the unused bundled plugins disabled (`grafana.ini` `disable_plugins`, `preinstall_disabled`). Verified: 2 plugins instead of 21, Ready in under 40 s with 0 restarts, grafana container 344Mi and 135m CPU. (A "~465Mi" figure quoted during the session was the **pod** total from `kubectl top pod`, sidecars included, and must not be compared with the 344Mi container value.)
- *Side note on the agent itself*: the bootstrap was launched as `bootstrap.sh > log; ...; tail log`, so the background-task notification reported **exit code 0** for a failed run. The real exit code was in the log (`EXIT=1`). Read the evidence, not the summary.
- *Lesson*: resource limits written before the software has ever run are guesses; measure them on first start (`kubectl top --containers`) and write the measured value in the comment.

**3.10 The VM froze: restart loops plus an uncapped kind node.**
- *What happened*: during the second bootstrap the desktop stopped responding for minutes and the VM had to be rebooted. In the cluster, emailservice and recommendationservice were in CrashLoopBackOff in both namespaces (23–25 restarts, exit 137 from liveness kills), so `boutique-prod` stayed `Progressing` for 20 minutes.
- *Diagnosis*: the obvious hypothesis (memory, no swap) was **wrong**: a 30 s sampler showed RAM flat at ~5.8 of 9.2 GB and the journal of the previous boot had no host OOM. The evidence pointed to CPU: a 2.5-minute gap in the sampler, a kernel warning about the NIC driver starved of CPU, load average ~14 on 4 vCPU, and CPU pressure still at 43% after the reboot. The Python services, with 20m requests (`kind-sizing`) and 200m limits, took longer to start than the upstream liveness window (3 × 5 s, no initial delay), and every restart burnt more CPU. The kind node container had no CPU cap, so the cluster could take every CPU from the desktop.
- *Fix*: (1) startup probes on every probed service in `kind-sizing` (same check as liveness, up to 150 s); (2) `bootstrap.sh` caps the node container at vCPUs − 1, no cap with 2 vCPUs or fewer (`KIND_NODE_CPUS`, validated as an integer from 0 to the vCPU count). Testing the cap found a second bug before the commit: `docker update --cpus 0` leaves an existing cap **unchanged**, so "0 = no cap" sets the cap to all CPUs instead. Third bootstrap: no restart loops, peak CPU pressure 81% but no freeze (no gaps in the sampler), peak RAM 6.7 GB.
- *Lesson*: lowering requests to fit a small node shifts the cost to start-up time; liveness windows designed for a production-sized cluster must be relaxed with startup probes, not by weakening liveness.

**3.11 Kyverno 1.20 refused the legacy policies, then its reports controller looped.**
- *What happened*: `platform-config` stayed OutOfSync: `Kyverno v1.20 removed execution of legacy kyverno.io policy types and no longer accepts create or update requests for them`. The 4 policies (written as `kyverno.io/v1` `ClusterPolicy`, validated by kubeconform against their CRD schema) **had never been active**. Same class of error as §3.1: the model's knowledge of the "current" API was out of date, and schema validation cannot detect a type the controller no longer serves.
- *Fix*: migration to `policies.kyverno.io/v1` `ValidatingPolicy` with CEL. The schema was taken from the installed CRDs (`kubectl explain`), not from memory. Explicit `autogen.podControllers` was added, then checked in the policy status: Kyverno rewrote `object.spec.containers` into `object.spec.template.spec.containers` (Deployments) and `jobTemplate...` (CronJobs). Verified with 9 server-side dry runs (5 must be denied, 4 allowed, all as expected) and with PolicyReports: the only failure is the expected `loadgenerator` without probes, so no false positives.
- *Follow-up issue*: once the policies existed, the Kyverno reports controller restarted 5 times in 10 minutes (exit 0). Its logs showed `Failed to renew lease ... context deadline exceeded`, then `leadership lost` and shutdown. Measurements: the controller alone used 1.8 CPU, the node 2.92 of its 3-CPU cap (throttled in 30% of periods), I/O negligible. Every restart reloaded caches for every API type and restarted the scan, which starved the API server and caused the next lost lease. Fix: CPU limit 500m (memory 256Mi) on the reports controller. After it: 0 restarts, scan completed in about 40 s, node down to 1.4 CPU.
- *Lesson*: "kubeconform -strict passes" proves the YAML matches a schema, not that the controller still accepts the type. For third-party controllers, the release notes of the version actually installed are part of validation; unpinned charts (README §5) made this surface on the first install.

**3.12 Argo CD rejected an Application with no destination namespace.**
- *What happened*: `platform-config` was `Unknown/Unknown` with `InvalidSpecError: ... namespace '' do not match any of the allowed destinations in project 'platform'`.
- *Fix*: `destination.namespace: monitoring`, used only as the default for namespaced resources without one (they all set it explicitly).
- *Lesson*: another rule that exists only at runtime (Argo CD admission), invisible to schema validation.

**3.13 Three wrong results from the verification scripts themselves.**
- *What happened*: the first runs of `smoke-test.sh` and `rbac-check.sh` on the cluster produced three wrong answers. None of them was a platform bug.
  1. **Checkout 422**: the test card was `4432-8015-6152-0454`. The frontend validator (`go-playground/validator` `credit_card`) accepts digits only; the upstream form uses `4432801561520454`. The `/metrics` counters gave the clue: the load generator's checkouts returned 200, ours 422.
  2. **False positive on prod metrics**: the prod run printed exactly the dev counters, **including two 422s that prod never received**. The port-forward was started through the `k()` function with `&`. A backgrounded function runs in a subshell, so `$!` was the subshell and cleanup orphaned `kubectl`. The orphan kept port 19090, the next port-forward failed silently, and the check read the **previous environment**.
  3. **Wrong RBAC matrix**: `kubectl auth can-i create pods/portforward` reads `pods/portforward` as TYPE/NAME (a pod named "portforward"), not as a subresource. Port-forward in dev showed `no` although the Role grants it, and "read logs" showed `yes` only because `get pods` is allowed.
- *Fix*: (1) the upstream card value; (2) `kubectl` started directly, plus a check that the port-forward process is alive, with the informational output printed only in that case; (3) `--subresource` for logs, exec and port-forward.
- *Verification of the fixes*: dev then prod, with the expected counters per environment and no process left behind. A **negative test** with an orphan dev port-forward now fails (exit 1). A first attempt at the negative test was itself invalid: `http.server` held only 127.0.0.1, so `kubectl` bound `[::1]` and the check legitimately passed. The RBAC matrix now matches `security.md` exactly.
- *Lesson*: tests need testing. A check that passes must be shown to fail when the condition is false, and the scenario used to show it must match the real failure.

**3.14 A functional change filed under `docs:`.**
- *What happened*: commit `563672cb` ("docs: separate measurements from inferences in comments") changed four files with comments or documentation only, and one admission policy: the autogen controllers of `require-requests-limits` gained `jobs` and `cronjobs`. Argo CD applied it to the cluster. The `docs:` type declared "no behaviour change", which was false for that file. The agent noticed only **after** the push.
- *Why it matters*: a reviewer skims `docs:` commits; a search for when the policy changed (`git log` filtered on `fix`/`feat`) would miss it; reverting the policy change would also revert unrelated comment fixes; tools that build changelogs from commit types would misreport it.
- *Cause*: the change came from a list of "precision" fixes (the migration had claimed the same coverage as before, which was not true for Jobs and CronJobs), and the commit type was chosen from the **reason** for the fix instead of its **effect** on the system.
- *First reaction, wrong*: the agent proposed leaving it as it was, because rewriting published history is worse than the error. That presented one trade-off as the only option, and it was a decision for the operator. The operator disagreed.
- *Fix, chosen by the operator from three options* (rewrite with force push / corrective commits / document only): no history rewrite. `2f069040` removes only the policy line from the state of `563672cb`, and `f5c9136e` re-applies it as `fix(policies):`. The two commits and this entry went in **one push**, so Argo CD synced only the final revision: the intermediate state was never applied to the cluster, and the final content equals `563672cb`. `563672cb` keeps its wrong title; the next commit names it explicitly.
- *Lesson*: before every push, read `git show --stat` for each commit and ask "which of these files changes behaviour?". The commit type describes the effect, not the motivation. When an error is found after the fact, present the options to the operator; do not pick one by preference.

**3.15 After a VM reboot the Gateway was dead while everything looked green.**
- *What happened*: after the VM was restarted overnight, all three Argo CD applications were Synced/Healthy and every pod Running, but `dev.boutique.local` and `boutique.local` refused connections on port 80. It surfaced only because the new `verify_frontend` check (step 8) curls through the Gateway.
- *Diagnosis* (read-only): Docker had also **swapped container IPs**: the Envoy gateway container moved from `172.18.0.3` to `172.18.0.2`, and `/etc/hosts` now pointed at the kind node. But port 80 was closed on both IPs, so `/etc/hosts` was not the whole story. The Envoy log repeated `StreamAggregatedResources gRPC config stream to xds_cluster closed ... upstream connect error`. Its command held a static config pointing to the cloud-provider-kind xDS server at `172.17.0.1:39119`, while the cloud-provider-kind logs showed a **new random xDS port at every start**: 43253 (first bootstrap), 39119 (after the first reboot), 41299 (now). Docker had restarted the old Envoy container with the old port, and cloud-provider-kind reuses an existing container instead of recreating it.
- *Fix*: with the operator's approval, the stale container was removed. cloud-provider-kind recreated it 57 s later with port 41299; both hosts answered `/_healthz` = ok with `X-App-Version: 1.0.0` and no xDS errors. `bootstrap.sh` (idempotent, meant to be rerun after a reboot) now compares the xDS port in each `kindccm-gw-*` container with the port of the current cloud-provider-kind run (logs read only since its last start, since older runs' lines stay in `docker logs`), removes stale containers and waits until a container with the right port exists. Tested live on the healthy state (no-op) and with stubs for the stale case (detects, removes, waits, confirms), without taking the Gateway down a second time. Runbook §2.10 documents the case.
- *Lesson*: "Synced/Healthy" in Argo CD says nothing about the path in front of the cluster. A release check must go through the real entry point; it found this outage, which no other check had reported.

## 4. Troubleshooting case with AI

Run on 2026-11-17 in the VM, with Claude Code operating the cluster directly (kubectl, Prometheus API), scenario `chaos.sh netpol-typo dev`.

> **Bias, stated up front**: the agent had read `chaos.sh` before the run, so it knew which fault was injected. The diagnosis below follows runbook §2.2 starting from the symptoms only, but it is **not a blind test**. A credible follow-up: the operator injects a scenario without telling the agent which one.

| | |
|---|---|
| **Observed symptom** | `POST /cart/checkout` → **500** (smoke test), every pod `Running`/`Ready`, then **`BoutiqueCheckoutFailing` firing** for `boutique-dev` (active 23:53:50, firing about 1 minute later as per `for: 1m`). The rest of the shop worked. |
| **Input given to the AI** | No pasted output: the agent ran the runbook commands itself (pod status, frontend and checkoutservice logs, NetworkPolicies, Argo CD status, labels, Prometheus alerts). No Secrets read or printed. |
| **Prompt** | The operator's instruction was only "proceed with netpol-typo". The working rules from the handover applied: symptom → 2–3 hypotheses ordered by likelihood → read-only checks → fix only through Git. |
| **Proposed hypotheses** | Two rounds were needed, because the fault **did not produce a symptom at first** (see "What the run taught"). On the real symptom: (1) network: NetworkPolicy or Service selector, since pods were healthy and the error was a dial timeout; (2) paymentservice itself unhealthy; (3) a recent change to the payment path. The evidence pointed at (1) immediately. |
| **Proposed verification commands** | Run, all read-only: `logs deploy/frontend` (→ `failed to charge card ... dial tcp 10.96.100.234:50051: i/o timeout`), `get pods` (all Ready), `get svc paymentservice` (the IP in the error), `get app boutique-dev` (OutOfSync, **only** `NetworkPolicy/paymentservice`), `get networkpolicy paymentservice -o jsonpath='{.spec.ingress}'`, `get pods -l app=checkoutservice --show-labels`. Not used: `kubectl debug` on the distroless pod (PSA `restricted` would need `--profile=restricted`); temporary labelled test pods were used instead (below). |
| **Root cause identified** | Ingress of `paymentservice` allowed `app=checkout-service` while the pods are labelled `app=checkoutservice`. It was manual drift from Git, flagged by Argo CD. Time from the first 500 to the root cause: about **40 seconds** (23:52:49 → 23:53:30). |
| **Fix** | `chaos.sh restore dev` = Argo CD sync from Git (23:54:59). No `kubectl edit`. |
| **Verification** | NetworkPolicy back to `app=checkoutservice`; smoke test dev **PASS (11 checks)** at 23:55:16; 5xx rate back to **0**; **alert resolved by itself** at 23:59:56 (the rule uses a 5-minute rate window). |
| **Value** | The runbook path itself was short; the value was in what did **not** go as expected. The agent did not accept "the checkout works, so the scenario is broken" and separated three explanations with evidence. Without the AI I would probably have concluded that kindnet does not enforce NetworkPolicies and lost time there. |

**What the run taught (three real findings):**

1. **The first injection was silently undone by Argo CD.** In dev `selfHeal` is off, but `automated` sync is on, and Argo CD synced 2 seconds after the injection because a new commit had just reached `main` (an unrelated monitoring fix). With `automated` + `selfHeal: false`, manual drift in dev survives only **until the next commit to `main`**, not "until you fix it". The `chaos.sh` comment was wrong and is fixed. The demo must not push during a chaos scenario.
2. **With the fault active, checkout still worked.** Hypotheses: (a) the existing gRPC connection checkout → payment survives the new policy; (b) kindnet does not enforce NetworkPolicies; (c) another policy allows the traffic. (c) was ruled out by listing the policies that select paymentservice (`deny-all` + `paymentservice` only). To separate (a) from (b), temporary PSA-compliant pods labelled `app=checkoutservice` opened **new** connections: `shippingservice:50051` **OPEN**, `paymentservice:50051` **BLOCKED**. So kindnet enforces, selectively, and (b) is ruled out. A pod labelled with the typo could not even resolve DNS (default-deny egress), which confirms enforcement but was useless as a positive control. Restarting checkoutservice (what any later deploy would do) produced the 500 at once, which confirms (a). **Lesson for operations**: a broken NetworkPolicy can stay invisible for hours and surface on an unrelated restart. "It broke after the deploy" does not mean "the deploy broke it".
3. **The runbook sent the operator to the wrong log first.** `checkoutservice` does not log the failure; it returns it to the caller. Only the **frontend** log has `failed to charge card ... i/o timeout`. Runbook §2.2 now starts from the frontend log and mentions long-lived connections.

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

- [x] Full `go build` of the frontend (toolchain 1.27): verified by the first green CI run (`go vet`, `go test -race` on the whole module, image build). See §3.8
- [ ] cloud-provider-kind: Gateway gets an address and routes by host; whether the `exclude-from-external-load-balancers` label must be removed from the single node
- [x] kindnet actually enforces NetworkPolicies (default deny + `netpol-typo`): new connections from an `app=checkoutservice` pod were OPEN to shipping and BLOCKED to payment under the typo; default-deny egress blocked DNS for an unlabelled pod. Existing connections are **not** cut (§4)
- [x] Redis with `--requirepass $(REDIS_PASSWORD)` and cartservice with a `password=` connection string work: `PING` without auth → `NOAUTH`, with the Secret → `PONG` (dev and prod); cart and checkout pass the smoke test. Trade-off: the password is visible in the Redis process command line to whoever can exec into the pod (no human persona can)
- [x] Kyverno policies: ~~the `"*:* & !*:latest"` syntax, per-rule `failureAction`~~ Kyverno 1.20 no longer admits `ClusterPolicy`: migrated to CEL `ValidatingPolicy`; 9 dry-run admission tests as expected; PolicyReports show only the expected `loadgenerator` finding, so no false positives (§3.11)
- [x] PSA `restricted` admits every pod (including the load generator's init container): both namespaces enforce `restricted`; dev 12/12 and prod 13/13 pods Running, load generator init container `Completed`
- [x] kube-prometheus-stack, Kyverno and Argo CD values with the current chart versions: kube-prometheus-stack 93.3.1, kyverno 3.10.0, argo-cd 10.18.0, metrics-server 3.14.0. Three values needed runtime fixes: Grafana resources and plugins (§3.9), Kyverno reports-controller limits (§3.11)
- [x] Dashboard panels and alerts with real data: every panel query run against Prometheus for dev and prod returns data (the "waiting reason" query is empty while nothing waits, as expected); 8 rules loaded with correct runbook anchors; `BoutiqueCheckoutFailing` fired and resolved in the netpol-typo run. Two leftovers from disabling Alertmanager fixed (an always-firing rule, a dangling Grafana datasource)
- [x] `helm lint`/`helm template` of the Krateo chart: verified in CI (1 chart linted, rendered Application valid under `kubeconform -strict`)
- [ ] Krateo PoC: CDC permissions to create Applications in `argocd`
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

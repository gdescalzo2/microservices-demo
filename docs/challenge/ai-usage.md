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

**3.16 The first real release: a failed sync that the old script would have called a success.**
- *What happened*: `release.sh dev 1.1.0` built and loaded the image, pushed the release commit `e48e706c`, then stopped after 300 s: `OutOfSync ... at e48e706c`. The sync operation had ended in `Error`: `ComparisonError ... dial tcp ...:8081: connection refused`. The Argo CD repo-server had been killed by its liveness probe at 08:31:24 UTC and restarted at 08:31:28; the sync started at 08:31:25. `argocd-server` had been restarted the same way shortly before, during the image build on the host (outside the node's CPU cap). CPU starvation is the likely cause; it was not measured.
- *Why it matters*: before this session's changes, `release.sh` slept 5 s, ran `rollout status` on the old, already rolled-out Deployment and printed `X-App-Version` without comparing it: it would have reported success with dev still on 1.0.0. The new checks (`wait_app_at_revision`, `verify_frontend`) stopped it. Argo CD does not retry a failed sync by default.
- *Fix*: the same commit synced again by hand (`argocd_sync` + the two checks): Synced at `e48e706c`, all checks ok, smoke test PASS. Then a retry policy (`limit 5`, backoff 5 s ×2) on the three Applications, on the operation `argocd_sync` starts (it does not inherit `spec.syncPolicy.retry`) and in the Krateo chart. Field names checked with `kubectl explain` on the installed CRDs.
- *Verification*: the same controlled test before and after (repo-server scaled to 0, sync, repo-server back after 15 s). Before: `Error`, `retryCount 0`. After: retry attempt #1 started 37 s after the operation, `Succeeded`, `retryCount 1`.
- *Two errors of the agent in the fix itself, caught before the push*: (1) the comment claimed "backoff ~155 s stays within the 300 s wait": the backoff is 155 s, but the after-test took 3 min 15 s, mostly the sync itself (~2 min 40 s with a cold repo-server). Worst case estimated at ~7 min, so the script wait was raised to 600 s and the comment rewritten with the measured values. Caveat reported by the operator afterwards: during the after-test a Chrome browser on the VM was using 100% CPU (closing it dropped the load from ~70 to below 3), so these durations are probably overestimated; the retry result itself is not affected, and 600 s only errs on the safe side. The release failure an hour earlier happened before the browser load started. (2) The comment for that change was inserted on the same line **before** `|| die`, which turned `|| die` into a comment: the script would have continued after a failed wait. shellcheck does not flag it. It was seen in the `grep` output, fixed, and proved by running the real line of both scripts with a 5 s timeout and a wrong SHA: both exit 1.
- *Lesson*: a check is only as good as what it compares against: "Synced" must be tied to the exact commit, and a version header must be compared, not printed. And a comment on a line of shell can disable code: read every edited line back, do not rely on the linter.

**3.17 `kustomize edit set image` rewrote the whole overlay.**
- *What happened*: reading the diff printed by the prod promotion (`55cb4c2d`) showed 35 changed lines for a one-tag release: every list re-indented, the comments explaining the HPA CPU request and the strategic-merge patch moved away from their patches, `includeSelectors: false` dropped, `newName` added. The dev release (`e48e706c`, 26 lines) had done the same. `release.sh` used `kustomize edit set image`, which loads the file and writes it back in kustomize's own format.
- *Impact check*: the first comparison of the rendered manifests was **wrong**: only `platform/deploy` was extracted from Git, the builds failed (the base reuses upstream `kustomize/base`), and `diff` of two empty files said "identical". Redone with `kustomize/` included and a line count to reject empty output: for both commits the rendered manifests differed by the image line only. The cluster was right; the source was damaged.
- *Order mattered*: `rollback.sh` reverts the last commit on the overlay, so a formatting fix committed on top of the promotion would have been reverted instead of the release. The planned prod rollback ran first and restored the overlay byte for byte (`git diff` against the pre-release commit: 0 lines); the dev release was rolled back the same way.
- *Fix*: `set_image_tag` in `lib.sh` changes only the `newTag` value of the entry named after the image (indentation, quoting and trailing comments kept; fails with the file untouched unless exactly one entry matches). `release.sh` now requires `git diff --numstat` "1 1" and a rendered diff of exactly two lines (old image, new image), or it restores the file and stops. Tested on the real overlays and on crafted cases (quoted values: a first version dropped the quotes, which would turn a tag like `1.10` into the number 1.1; fixed), and the real `release.sh` block run in a temporary git worktree, with stubs to exercise the restore paths. The dev release redone with the fixed script (`14279bcb`): one line changed.
- *Lesson*: read the diff of every generated commit, even when the tool "only sets a tag". And a comparison that cannot fail (two empty files) is not a check: verify the inputs are non-empty first.

**3.18 The Krateo PoC on a real cluster: what the script got wrong.**
- *What happened*: the PoC worked end to end (chart → CRD `v0-1-0` → controller → Helm release → Argo CD Application → 12 pods → `/_healthz` 200), but `krateo-poc.sh` itself had four defects, none of them visible without a cluster:
  1. `install` would have pointed the CompositionDefinition at an unpublished `oci://ghcr.io` URL: its `sed` looked for the `YOUR_GITHUB_USER` placeholder that `set-github-user.sh` had already replaced (fixed earlier with `render_repo_url` and `render_definition`, which fail when the URL is not exactly the expected one);
  2. `status` selected Applications by `app.kubernetes.io/managed-by=krateo` and printed "No resources found" for a healthy instance: core-provider's Helm client overwrites that label with `Helm`;
  3. the instance manifest was echoed with `tee /dev/stderr`: with stderr redirected to a log file, `tee` reopened the file with `O_TRUNC` and wiped the log written so far (the first install log was lost and full of NUL bytes);
  4. `status` ended with `[[ -n "$IP" ]] && echo …`, which returns 1 when the Gateway has no address and makes `status` fail.
- *Also*: `install` returned 0 as soon as the instance object was created; it does not wait for the workload, so "exit 0" did not mean "the instance works". The end-to-end check was done by hand.
- *Fix*: `status` selects by AppProject `boutique-selfservice`; the manifest comes from `render_instance`, is printed on stdout and applied from a variable (no second open of the log); explicit `if` for the IP; `render` also prints the instance manifest.
- *Verification*: `status` shows `team-a-dev Synced/Healthy` and exits 0; `render > log 2>&1` gives a complete log with no NUL bytes; the rendered instance is `unchanged` in a server-side dry run against the live object; the old `tee /dev/stderr` pattern, run the same way, loses its first line and leaves NUL bytes, so the test does detect the defect. The empty-IP branch is not exercised (it needs a Gateway without an address).
- *Lesson*: a PoC script is code too. Every assumption it makes about a third-party tool (label ownership, placeholders already replaced, file descriptors) has to be checked against the real system, and "exit 0" has to mean the outcome the user cares about.

**3.19 The VM thrashed, and the agent first blamed the wrong resource.**
- *What happened*: on 2026-11-18, after the CPU-plan commits (`efe21c6c` node cap at 3.5 vCPU, `713ab801` kubelet CPU reservations, `e790ec97` sync waves) were pushed, with dev, prod and the Krateo instance `team-a-dev` running (three copies of the app), the VM and the Windows host became almost unusable: load average ~80.
- *Agent errors*: (1) it inferred a memory shortage from the low "free" value of `free`; the operator pointed out that most of it was page cache, which Linux always fills. (2) It then said the disk reads came from outside the pods; per-cgroup `io.stat` attributed them to the pods. Both were claims made before reading the direct counter.
- *Diagnosis with direct counters*: memory pressure (PSI) 43%, I/O pressure 81%, ~83,000 `workingset_refault_file` per second. The kernel kept dropping executables and libraries from the cache and reading them back. The VM had 10 GiB and **no swap**, so rarely used anonymous memory could not leave RAM and only file cache could be reclaimed. CPU `iowait` was low, which misled at first: it only counts idle CPUs, and the CPUs were busy.
- *Fix*: the Krateo instance was removed (load back to normal); then, as operator decisions, +2 GiB RAM and a 2 GiB swap file. With the same three environments, the Krateo instance re-created later peaked at load 4.6 instead of ~80, with refaults near 0. All 66 pod containers run with `memory.swap.max=0` (kubelet `NoSwap`, the default): only processes outside the pods (desktop, containerd, dockerd) used the swap, ~200 MB.
- *Root cause, as the operator put it*: memory was never planned. The CPU got a budget (requests that add up to the cap, staged rollouts), memory did not.
- *Lesson*: "free" is not pressure. Measure PSI and refault rates before naming a resource, and give every resource an explicit budget before adding workloads.

**3.20 Swap, zswap and kdump: claims checked against sources and the machine.**
- *Swap*: the operator held that swap should always be configured. Checked: on Linux it is recommended even with free RAM (Chris Down, kernel memory-management developer, "In defence of swap": swap is "a mechanism for equality of reclamation", and without it the disk I/O moves to dropping page cache), which matches §3.19. Two related claims were **not** supported by the sources read: Linux core dumps do not need swap (`core(5)` lists the failure causes, swap is not one; on this VM, apport wrote process dumps on 2026-11-17, before the swap file existed on 2026-11-18). On Windows, system crash dumps do need a page file or a dedicated dump file (Microsoft docs), while for user-mode process dumps (WER `LocalDumps`, ProcDump) the docs list a folder and its permissions, not a page file. Whether Process Monitor needs a page file to buffer events could not be verified from its public page.
- *zswap*: the operator enabled zswap with `zswap.compressor=lz4` on the kernel command line. After the reboot the kernel logged `zswap: compressor lz4 not available, using default lzo`: on the Ubuntu kernel `lzo` is built in, `lz4` is a module (`crypto/lz4.ko`), and the initramfs did not contain it when zswap initialised. `lz4` was added to `/etc/initramfs-tools/modules`; the initramfs was first regenerated **before** that edit (so the next boot fell back again), then once more after it: `zswap: loaded using pool lz4`. Pool limit set to 2% of RAM; it is a ceiling, not a reservation.
- *kdump*: 512 MiB of RAM were reserved by `crashkernel=` while kdump was disabled (`USE_KDUMP=0`, `kexec_crash_loaded=0`): memory paid for no protection. The agent first suggested `apt remove kdump-tools`; `dpkg-query` showed the GRUB snippet with `crashkernel=` is a **conffile**, which `remove` keeps. In the operator's removal, `update-grub` ran between `remove` and `purge` (dpkg log and file times), so the next boot still reserved the memory; a new `update-grub` fixed it.
- *Result, measured after a reboot with 11 GiB (the host needed 1 GiB back)*: `MemTotal` 10,900 MiB; during the restart of all 64 pods memory pressure stayed below 1% and 4.5 GiB remained available; zswap held ~75 MB; 909 pages (3.6 MB) written to the swap file in the 15 minutes measured.
- *Lesson*: a kernel parameter on the command line is not enough when it names a module: check the boot log for the fallback. And "removed" in a package manager is not "gone": check which files are conffiles.

**3.21 After another reboot: no logs to read the port from, and swapped IPs again.**
- *What happened*: after the 2026-11-19 reboots the Gateway refused connections again (§3.15). This time `bootstrap.sh` could not fix it: cloud-provider-kind ran for 15+ minutes **without writing any log line**, so the xDS port could not be read and the stale-container check was skipped with a warning. Docker had also given the node and the Envoy container each other's IP again (Gateway now `172.18.0.3`), so `/etc/hosts` was stale.
- *Diagnosis*: `ss -ltn 'src 172.17.0.1'` showed one listener, the new xDS port; cloud-provider-kind uses host networking and its Envoy config points to the Docker bridge gateway address. The stale container was removed with the operator's approval; with the new IP both hosts answered 200.
- *Fix* (`017cd658`): `cpk_xds_port` falls back to the socket and returns a port only if exactly one listener is on that address; the `/etc/hosts` check requires the exact project line instead of any line starting with the IP. Tested on the live cluster (no log line → 38911) and with stubs (log line wins; zero listeners, two listeners, invalid bridge IP → empty). Runbook §2.10.
- *Lesson*: when a fix depends on parsing a log line, plan for the line not being there.

**3.22 Smaller agent errors in the same two days, all caught by checking output.**
- Commit `50ed2fb5` says the pinned charts caused "no changes to the releases". In fact the `helm upgrade` calls created new Helm revisions (no pod was recreated; only the Kyverno `migrate-resources` hook job ran). Left in history, recorded here.
- A background performance sampler was reported as started after a reboot; it had not run at all: `/tmp` is a tmpfs, the script was gone, and the `ls … && nohup …` chain failed silently. Now: after starting a background process, check that it is alive and writing.
- Two Gateway checks used the hostname `boutique-dev.local` instead of `dev.boutique.local`; the 404 it produced was noticed and the check redone with the right name.
- An `EXIT=7` was reported without saying it was the last `curl`, which suggested `kubectl` had failed.
- *Lesson*: report every exit code next to the command it belongs to, and verify that a started process actually exists before relying on its output.

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
- [x] cloud-provider-kind: Gateway gets an address and routes by host: dev and prod answer 200 on their hostnames through the Gateway IP. The `node.kubernetes.io/exclude-from-external-load-balancers` label is not on the kind node (checked with `--show-labels`), so nothing had to be removed. After a VM reboot the Gateway needs `bootstrap.sh` (§3.15, §3.21)
- [x] kindnet actually enforces NetworkPolicies (default deny + `netpol-typo`): new connections from an `app=checkoutservice` pod were OPEN to shipping and BLOCKED to payment under the typo; default-deny egress blocked DNS for an unlabelled pod. Existing connections are **not** cut (§4)
- [x] Redis with `--requirepass $(REDIS_PASSWORD)` and cartservice with a `password=` connection string work: `PING` without auth → `NOAUTH`, with the Secret → `PONG` (dev and prod); cart and checkout pass the smoke test. Trade-off: the password is visible in the Redis process command line to whoever can exec into the pod (no human persona can)
- [x] Kyverno policies: ~~the `"*:* & !*:latest"` syntax, per-rule `failureAction`~~ Kyverno 1.20 no longer admits `ClusterPolicy`: migrated to CEL `ValidatingPolicy`; 9 dry-run admission tests as expected; PolicyReports show only the expected `loadgenerator` finding, so no false positives (§3.11)
- [x] PSA `restricted` admits every pod (including the load generator's init container): both namespaces enforce `restricted`; dev 12/12 and prod 13/13 pods Running, load generator init container `Completed`
- [x] kube-prometheus-stack, Kyverno and Argo CD values with the current chart versions: kube-prometheus-stack 93.3.1, kyverno 3.10.0, argo-cd 10.18.0, metrics-server 3.14.0. Three values needed runtime fixes: Grafana resources and plugins (§3.9), Kyverno reports-controller limits (§3.11)
- [x] Dashboard panels and alerts with real data: every panel query run against Prometheus for dev and prod returns data (the "waiting reason" query is empty while nothing waits, as expected); 8 rules loaded with correct runbook anchors; `BoutiqueCheckoutFailing` fired and resolved in the netpol-typo run. Two leftovers from disabling Alertmanager fixed (an always-firing rule, a dangling Grafana datasource)
- [x] `helm lint`/`helm template` of the Krateo chart: verified in CI (1 chart linted, rendered Application valid under `kubeconform -strict`)
- [x] Krateo PoC: CDC permissions to create Applications in `argocd`: the instance's Helm release created the Application in `argocd` with no extra RBAC; instance Synced/Healthy, 12/12 pods, `/_healthz` 200 through the Gateway (§3.18, krateo.md §5)
- [x] Memory usage: peak 7.7 GB in use (`MemTotal − MemAvailable`, Prometheus, 24 h including bootstraps and the Krateo instance), against the 6–7 GB estimate. Sizing and swap in §3.19–§3.20
- [ ] Real bootstrap duration **from scratch**: not re-measured. A rerun on an existing cluster (all steps idempotent, Gateway repaired) took under 4 minutes

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

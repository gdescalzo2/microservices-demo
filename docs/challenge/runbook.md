# Operations runbook

For whoever is on call for Online Boutique. Every Prometheus alert links to a section of this document (`runbook_url`). All commands assume:
- the `kind-boutique` context;
- the environment in `$NS`;
- the Argo CD app in `$APP`.

```bash
export NS=boutique-dev APP=boutique-dev        # or boutique-prod
alias k=kubectl
```

## 0. Method

Understand first, then change. The order:

1. **Symptom**: what does the user see, or which alert fires? Since when?
2. **Scope**: one environment or both? One route or all of them? One pod or every replica? Did something change (release, Argo CD sync, manual drift)?
3. **Hypotheses**: 2–3 at most, ordered by likelihood and by how cheap they are to check.
4. **Evidence**: events → pod status → logs → metrics → configuration. For each hypothesis, the command that confirms or rules it out.
5. **Mitigation**: restore service first (rollback, sync from Git, scale), then the permanent fix through Git.
6. **Verification**: smoke test, metrics back to normal, alert resolved.
7. **Close-out**: what happened, why we did not see it earlier, what we change (alerts, tests, policies).

**The key question in a GitOps system**: *does the cluster match Git?* `kubectl -n argocd get app` immediately shows drift (`OutOfSync`) or a failed sync.

**When to escalate** (to the platform team or to development):
- the problem involves shared components (Gateway, Argo CD, Kyverno, node, DNS), so several namespaces or every service;
- the fix needs a code or policy change;
- rollback does not help: the problem is not in the last release;
- there is a risk of data loss or a security issue (exposed Secret, unusual access).

Hand over with the escalation: symptom, start time, environment, what was checked and ruled out, what was already tried.

## 1. Health verification (checklist)

```bash
# GitOps: is the cluster aligned?
k -n argocd get applications
#   SYNC = Synced, HEALTH = Healthy for platform-config, boutique-dev, boutique-prod

# Workloads
k -n $NS get deploy                       # READY = desired/available
k -n $NS get pods -o wide                 # STATUS, RESTARTS, node
k -n $NS get events --sort-by=.lastTimestamp | tail -20

# Network and exposure
k -n gateway-infra get gateway boutique-gateway       # PROGRAMMED=True, ADDRESS set
k -n $NS get httproute frontend -o jsonpath='{.status.parents[0].conditions}' | jq
k -n $NS get svc,endpointslices               # every Service has ready endpoints

# Configuration
k -n $NS get secret redis-auth                 # must exist (do not print its content)
k -n $NS describe deploy frontend | sed -n '/Environment/,/Mounts/p'

# Functional
platform/scripts/smoke-test.sh dev
```

Available health checks:

| Service | Liveness / readiness | Notes |
|---|---|---|
| frontend | HTTP `GET /_healthz` (port 8080) + startup probe | static, does not check backends |
| gRPC services | native Kubernetes `grpc` probe (gRPC health protocol) | |
| redis-cart | TCP 6379 | |
| loadgenerator | none | known exception (load client), reported by Kyverno in audit |

```bash
# run a health check by hand
k -n $NS port-forward deploy/frontend 8080:8080 & curl -s localhost:8080/_healthz; kill %1
k -n $NS get pods -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
```

Logs (all JSON on stdout):

```bash
k -n $NS logs deploy/frontend --since=10m | jq -r 'select(.severity!="debug") | [.timestamp,.severity,."http.req.path",."http.resp.status",.message] | @tsv' | tail
k -n $NS logs deploy/checkoutservice --since=10m | tail -20
k -n $NS logs deploy/frontend --previous      # logs of the container before its last restart
```

Metrics (Prometheus: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`):

```promql
sum by (route, code) (rate(boutique_frontend_http_requests_total{namespace="boutique-prod"}[5m]))
histogram_quantile(0.95, sum by (le, route) (rate(boutique_frontend_http_request_duration_seconds_bucket{namespace="boutique-prod"}[5m])))
count by (version) (boutique_frontend_build_info{namespace="boutique-prod"})
```

## 2. Troubleshooting by symptom

<a id="rb-frontend-errors"></a>
### 2.1 The frontend returns 5xx (`BoutiqueFrontendHighErrorRate`)

1. **Which route?** Use the dashboard panel "Errors by route and code", or:
   `sum by (route, code) (rate(boutique_frontend_http_requests_total{namespace="$NS",code=~"5.."}[5m]))`
2. The route points to the backend:

   | Route | Backends |
   |---|---|
   | `/` | catalog, currency, ad, recommendation, cart |
   | `/product/{id}` | catalog, currency, recommendation, ad |
   | `/cart` | cart (and therefore Redis), shipping |
   | `/cart/checkout` | see [§2.2](#rb-checkout) |
3. The frontend error log names the service and the gRPC code:
   `k -n $NS logs deploy/frontend --since=10m | grep -i '"severity":"error"' | tail -5`
   - `Unavailable` / `connection refused` → the backend has no endpoints: `k -n $NS get endpointslices -l kubernetes.io/service-name=<svc>`
   - `DeadlineExceeded` → slow backend, or traffic blocked by a NetworkPolicy (dropped packets time out instead of failing fast)
   - `Unauthenticated` / `NOAUTH` (cartservice) → Redis password mismatch, see [§2.8](#rb-secret)
4. Correlate with recent changes: `k -n argocd get app $APP -o jsonpath='{.status.history}' | jq '.[-3:]'`, `git log -5 -- platform/`.

<a id="rb-checkout"></a>
### 2.2 Orders fail (`BoutiqueCheckoutFailing`)

Checkout calls cart, catalog, currency, shipping and payment. Email and cart-emptying errors are tolerated.

**A refused card is not a failure.** Since frontend 1.2.0 a card declined by paymentservice (unsupported brand, invalid number, expired) is answered **402** and logged at `warning` as `payment declined` with a `decline_reason`; the alert counts only 5xx, so declines do not fire it. The load generator produces a few by itself (~0.6% of its orders: random "VISA" numbers that are Visa Electron). Before that version they surfaced as 500s and fired this alert with no fault (ai-usage §3.26). `code="402"` in `boutique_frontend_http_requests_total` shows how many.

```bash
k -n $NS logs deploy/frontend --since=1h | jq -cR 'fromjson? | select(.message=="payment declined") | .decline_reason' | sort | uniq -c
```

A slow failure can reach the shopper as **504** from the Gateway rather than 500 from the frontend: Envoy stops waiting before the frontend's call times out (seen with `netpol-typo`, first order after the fault). The frontend log still has the error.

Start from the **frontend** log: checkoutservice returns the error to its caller and does not log it, so its own log shows only `[PlaceOrder]` lines.

```bash
k -n $NS logs deploy/frontend --since=10m | grep -i checkout | grep -iE 'error|fail' | tail -3
#   "failed to charge card"  -> paymentservice
#   "shipping error"         -> shippingservice
#   "failed to get user cart"/"cart failure" -> cartservice / redis
k -n $NS get pods -l 'app in (paymentservice,shippingservice,cartservice,redis-cart)'
k -n $NS get networkpolicy                                   # any recent change?
k -n argocd get app $APP                                      # OutOfSync = someone touched the cluster
```

If every pod is `Running`/`Ready` but calls time out (`dial tcp <ClusterIP>:<port>: i/o timeout`), the first hypothesis is the **network**: a NetworkPolicy, or a Service with the wrong selector.

A broken NetworkPolicy does **not** cut connections that already exist: gRPC keeps long-lived connections, so the fault can stay invisible until the caller restarts, for example during an unrelated deploy. "It broke after the deploy" does not prove the deploy is the cause: check `k -n argocd get app $APP` for drift and the NetworkPolicy history.

```bash
k -n $NS get networkpolicy paymentservice -o jsonpath='{.spec.ingress}' | jq
k -n $NS get pods -l app=checkoutservice --show-labels     # the real label to allow
# connectivity test from the checkout pod (distroless image: no shell, use a debug container):
k -n $NS debug -it deploy/checkoutservice --image=busybox:1.38.0 --target=server -- nc -zvw3 paymentservice 50051
```

> Note: `kubectl debug` creates an ephemeral container that PSA `restricted` may reject. In that case use `--profile=restricted` (kubectl ≥ 1.30), or run the test in dev from a temporary pod labelled `app=checkoutservice`.

Mitigation:
- dev → `platform/scripts/chaos.sh restore dev` (sync from Git);
- prod → Argo CD self-heal realigns on its own;
- if the fault comes from Git → `rollback.sh prod`.

<a id="rb-latency"></a>
### 2.3 High latency (`BoutiqueFrontendLatencyHigh`)

1. All routes or one? Check the "p95 latency by route" panel.
2. CPU throttling? The frontend CPU limit is 200m:
   `sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="$NS"}[5m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="$NS"}[5m]))`
3. Is the node saturated? `kubectl top node`, `kubectl top pods -n $NS --sort-by=cpu`
4. HPA (prod): `k -n boutique-prod get hpa frontend`. Is it at max replicas? Does `TARGETS` show `<unknown>`? Then metrics-server is not responding.

<a id="rb-metrics-down"></a>
### 2.4 Prometheus cannot scrape the frontend (`BoutiqueFrontendMetricsDown`)

```bash
k -n $NS get servicemonitor frontend
k -n $NS get endpointslices -l kubernetes.io/service-name=frontend-metrics
# Prometheus UI -> Status -> Targets -> "serviceMonitor/$NS/frontend/0": error shown there
k -n $NS port-forward svc/frontend-metrics 19090:9090 & curl -s localhost:19090/metrics | head; kill %1
```

Typical causes:
- the frontend is not ready, so the Service has no endpoints;
- the `metrics` port was renamed;
- a NetworkPolicy blocks the `monitoring` namespace.

<a id="rb-pod-waiting"></a>
### 2.5 Stuck pod: ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError (`BoutiqueContainerWaiting`, `BoutiquePodRestarting`)

```bash
k -n $NS get pods | grep -v Running
k -n $NS describe pod <pod> | sed -n '/State:/,/Ready:/p;/Events:/,$p'
```

| Reason | Meaning | What to check |
|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | image or tag does not exist, registry unreachable, credentials | `describe` → pull message; tag in the overlay; on kind: `docker exec boutique-control-plane crictl images \| grep frontend` |
| `CrashLoopBackOff` | the process exits immediately | `k logs <pod> --previous`; exit code in `Last State` (137 = OOM or SIGKILL, 1/2 = application error, e.g. a missing environment variable) |
| `CreateContainerConfigError` | referenced Secret or ConfigMap missing | `describe` → "secret \"redis-auth\" not found" → [§2.8](#rb-secret) |
| `RunContainerError` / `CreateContainerError` | security or runtime constraints | `describe`; e.g. `readOnlyRootFilesystem` with an app that writes to disk |

Exit code 137 with `Reason: Error` (not `OOMKilled`) and a `Killing ... failed liveness probe` event means the kubelet killed a container that was **too slow to start**, usually because of CPU contention. Each restart burns more CPU, so the loop feeds itself. Check the node load ([§2.11](#rb-host-cpu)) and that the Deployment has a `startupProbe` (the `kind-sizing` component adds one to every probed service).

<a id="rb-oom"></a>
### 2.6 OOMKilled (`BoutiqueContainerOOMKilled`)

```bash
k -n $NS describe pod -l app=<svc> | grep -A5 'Last State'        # Reason: OOMKilled, Exit Code: 137
k -n $NS get deploy <svc> -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq
```

PromQL: actual usage against the limit.

```promql
max by (pod) (container_memory_working_set_bytes{namespace="$NS",container="server"})
  / on (pod) group_left max by (pod) (kube_pod_container_resource_limits{namespace="$NS",resource="memory"})
```

Is the limit too low, or is there a leak?
- **Leak**: the working set grows steadily up to the limit. Escalate to development.
- **Limit too low**: a spike under normal load. Fix it **in Git** (a patch in the overlay), never only with `kubectl set resources`: in prod the change would be reverted, in dev it would stay as drift.

<a id="rb-rollout-stuck"></a>
### 2.7 Stuck rollout (`BoutiqueDeploymentReplicasMismatch`)

```bash
k -n $NS rollout status deploy/frontend --timeout=10s
k -n $NS get rs -l app=frontend            # old RS still active, new RS with pods not ready
k -n $NS rollout history deploy/frontend
```

With `maxUnavailable: 0` a failed rollout **does not reduce capacity**: the old pods stay in service and the new pod stays in error. The shop works; the only problem is that the new version does not get in. After `progressDeadlineSeconds` (600 s) the Deployment reports `Progressing=False` and Argo CD marks the app `Degraded`. Action: [rollback](#3-rollback).

<a id="rb-secret"></a>
### 2.8 Missing Secret or wrong Redis password

```bash
k -n $NS get secret redis-auth || platform/scripts/create-secrets.sh $NS
k -n $NS logs deploy/cartservice --since=10m | grep -iE 'redis|auth' | tail -5
k -n $NS logs deploy/redis-cart --since=10m | tail -5
```

Environment variables are read at start-up. After creating or rotating the Secret, restart Redis and cartservice (`create-secrets.sh --rotate` does it for you).

### 2.9 Argo CD: OutOfSync, Degraded, failed sync

```bash
k -n argocd get app $APP -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
k -n argocd get app $APP -o jsonpath='{.status.operationState.message}{"\n"}'
k -n argocd get app $APP -o json | jq '.status.resources[] | select(.status!="Synced" or .health.status!="Healthy") | {kind,name,status,health:.health.status,msg:.health.message}'
argocd app diff $APP          # with the CLI (after argocd login)
```

| Message | Cause |
|---|---|
| `admission webhook "vpol.validate.kyverno.svc-fail" denied the request: Policy <name> failed` | The change violates a `Deny` ValidatingPolicy (`:latest` tag, missing owner label). Fix the manifest in Git |
| `pods ... is forbidden: violates PodSecurity "restricted"` | The container does not meet PSA restricted (root, capabilities, seccomp) |
| `resource ... is not permitted in project` | The AppProject does not allow that resource or namespace (guardrail working as intended) |
| `OutOfSync` with no errors | Manual drift (dev), or a new commit not synced yet: run `argocd_sync` or wait for polling (60 s) |
| `ComparisonError: Failed to load target state ... dial tcp <IP>:8081: connect: connection refused` | The Argo CD repo-server was down (e.g. restarted by its liveness probe under CPU pressure). Syncs retry 5 times with backoff (`syncPolicy.retry`, and the same on `argocd_sync`): check `.status.operationState.retryCount` and `k -n argocd get pods -l app.kubernetes.io/name=argocd-repo-server` before acting |

### 2.10 The site does not respond (no pod in error)

```bash
k -n gateway-infra get gateway boutique-gateway -o wide     # ADDRESS empty?
docker ps --filter name=cloud-provider-kind                  # is the controller on the host running?
docker logs cloud-provider-kind --tail 30
getent hosts dev.boutique.local                              # does /etc/hosts point to the current Gateway IP?
curl -sv --resolve dev.boutique.local:80:$(k -n gateway-infra get gateway boutique-gateway -o jsonpath='{.status.addresses[0].value}') http://dev.boutique.local/_healthz
k -n $NS get httproute frontend -o jsonpath='{.status}' | jq   # Accepted / ResolvedRefs
```

**After a reboot of the VM** the Gateway can stay unreachable on both hosts (connection refused on port 80) while every pod is healthy. Envoy runs in a Docker container created by cloud-provider-kind, with the xDS port of cloud-provider-kind written into its command. cloud-provider-kind picks a new random port at every start, Docker restarts the old Envoy container with the old port, and Envoy never receives its listeners.

```bash
docker logs --tail 3 $(docker ps --format '{{.Names}}' | grep '^kindccm-gw-')   # "xds_cluster ... upstream connect error"
platform/scripts/bootstrap.sh     # idempotent: detects the stale container, removes it, cloud-provider-kind recreates it (~1 min)
getent hosts dev.boutique.local   # the container may get a new IP: bootstrap prints the /etc/hosts line to use
```

Two variants seen for real on 2026-11-19:

- cloud-provider-kind ran for 15+ minutes **without writing any log line**, so the xDS port could not be read from `docker logs`. `bootstrap.sh` then reads it from the socket: cloud-provider-kind uses host networking and serves xDS on the Docker bridge gateway address, so the port is the only TCP listener there (`ss -ltn 'src 172.17.0.1'`). With zero or several listeners it does not guess and skips the check with a warning.
- Docker gave the node and the Envoy container **each other's IP** (node `172.18.0.2`, Gateway `172.18.0.3`, the opposite of before). The Gateway works, but `/etc/hosts` points to the old IP: connection refused again. `bootstrap.sh` compares the exact `/etc/hosts` line and offers to update it.

A `404` from the Gateway (not from the frontend) means no HTTPRoute matches the host. Typical causes: wrong hostname, or a namespace without the `platform.example.com/gateway-access=true` label.

<a id="rb-host-cpu"></a>
### 2.11 The VM freezes or is very slow (host CPU saturated)

Symptoms: the desktop stops responding during the bootstrap or a rollout; many pods restart at once with exit code 137 and liveness failures.

```bash
uptime                                      # load average well above the vCPU count
cat /proc/pressure/cpu                      # "some avg60" > 30: tasks often wait for CPU
docker inspect boutique-control-plane --format '{{.HostConfig.NanoCpus}}'   # 0 = no CPU cap on the node
journalctl -b -1 -p warning | grep -iE 'oom|hung|lockup'   # after a forced reboot: was it memory or CPU?
k top pod -A --sort-by=cpu | head
```

The kind node is a Docker container; without a cap, pods can take every vCPU and starve the desktop. `bootstrap.sh` caps it at *vCPUs − 0.5* (3.5 on 4 vCPUs), with no cap on hosts with 2 vCPUs or fewer (`KIND_NODE_CPUS` overrides with a value from 0 to the vCPU count, at most one decimal; `0` disables). To apply or change it on a running cluster, without restarting anything:

```bash
docker update --cpus 3.5 boutique-control-plane
```

If the load comes from a restart loop, fix that first (§2.5): a container killed by its liveness probe during a slow start burns CPU on every attempt.

**Memory, not CPU?** "free" in `free -h` is not the signal: Linux fills idle RAM with page cache. Look at pressure and re-reads instead:

```bash
cat /proc/pressure/memory /proc/pressure/io            # "some avg10" well above 0 = tasks wait for memory / disk
grep -E '^(workingset_refault_file|pswpin|pswpout|zswpwb)' /proc/vmstat   # run twice 10 s apart: the delta is the rate
```

Thousands of `workingset_refault_file` per second mean the kernel keeps dropping and re-reading files it still needs (executables, libraries): page cache thrashing. Seen for real at ~83,000/s with no swap (ai-usage §3.19). With swap (zram on the reference VM), rarely used anonymous memory can leave RAM instead.

**After a VM reboot** the kubelet restarts every pod at once (the sync waves of `staged-sync` apply to Argo CD syncs, not to a node restart). Measured with 4 vCPU and the 3.5 cap (boot at 12:23): load 82 at 12:25, CPU pressure ~78% until 12:29, load below 10 from 12:32, memory pressure below 1% throughout. Wait for it to settle, then rerun `bootstrap.sh` for the Gateway (§2.10). Two things that look alarming after a reboot and are not:

- `local-path-provisioner` in `CrashLoopBackOff`: it exits with `level=fatal ... Get "https://10.96.0.1:443/..."` while the API server is not up yet, and recovers by itself (seen: 17 restarts, Running about 3 minutes after boot).
- High restart counters (seen: 27–41 on the Prometheus operator, kube-state-metrics, metrics-server, argocd-server, scheduler, controller-manager): they add up across VM reboots and past incidents. What matters is whether the counter still grows: `kubectl get pods -A -w`, or the `RESTARTS` column with its "(N m ago)".

## 3. Rollback

| Situation | Command | Notes |
|---|---|---|
| Bad release, Git available (**default**) | `platform/scripts/rollback.sh <env>` | `git revert` of the last overlay commit → push → sync. Tracked and reviewable |
| Emergency, Git or CI unavailable | `platform/scripts/rollback.sh <env> --emergency` | `kubectl rollout undo`; in prod it suspends auto-sync first. **Then realign Git** and re-enable auto-sync |
| From the Argo CD UI | App → History and rollback → previous version | Disables auto-sync on the app: re-enable it after fixing Git |
| Manual drift (dev only) | `platform/scripts/chaos.sh restore dev` | Sync from Git, undoes changes made with kubectl |

Why the default is `git revert` and not `kubectl rollout undo`: in prod, Argo CD self-heal would bring the cluster back to the Git state (the broken version) within about a minute. The "real" rollback must go through the source of truth.

After the rollback, verify:

```bash
k -n $NS rollout status deploy/frontend
curl -sI http://boutique.local/ | grep -i x-app-version
platform/scripts/smoke-test.sh prod
```

In Grafana, the "Frontend version(s) running" panel shows the version change.

## 4. Reproducible failure scenarios

Run them with `platform/scripts/chaos.sh <scenario> [dev|prod]`. Each scenario has a symptom, a diagnosis and a restore:

| Scenario | Symptom | How it is diagnosed | Restore |
|---|---|---|---|
| `bad-image` | rollout stuck, site **still working** | `rollout status` stalls, new pod `ImagePullBackOff`, `ContainerWaiting` alert | `chaos.sh restore` (dev) / `rollback.sh` |
| `netpol-typo` | only checkout fails (500), everything else OK, **all pods Ready** | 5xx metric on `/cart/checkout`, frontend logs "failed to charge card" + timeouts, NetworkPolicy with the wrong label | `chaos.sh restore` |
| `oom` | empty recommendations or errors on the product page, continuous restarts | `OOMKilled`, exit 137, 32Mi limit | `chaos.sh restore` |
| `redis-down` | cart and checkout fail | `redis-cart` Service without endpoints, errors in cartservice logs | `chaos.sh restore` (replicas are declared in Git, so Argo CD sees the drift) |

In prod the same scenarios show **self-heal**: Argo CD detects the drift and undoes it on its own (`k -n argocd get app boutique-prod -w`).

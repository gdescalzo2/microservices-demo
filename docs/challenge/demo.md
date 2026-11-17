# Demo script (about 45 minutes)

Each step maps to one mandatory point of the challenge (§7).

**Preparation**: the cluster is already up with `bootstrap.sh`. The first install takes 15–25 minutes, so it is not done live. Keep 4 terminals and 3 browser tabs open.

| Terminal | Content |
|---|---|
| T1 | demo commands (repo root) |
| T2 | `k9s` or `watch kubectl -n boutique-dev get pods` |
| T3 | `kubectl -n argocd port-forward svc/argocd-server 8080:80` |
| T4 | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` (+ Prometheus on 9090 if needed) |

| Browser | URL |
|---|---|
| Shop | http://dev.boutique.local and http://boutique.local |
| Argo CD | http://localhost:8080 (apps `boutique-dev`, `boutique-prod`, `platform-config`) |
| Grafana | http://localhost:3000 → dashboard **Online Boutique - Overview** |

**Pre-flight (5 minutes before)**:
- `smoke-test.sh dev && smoke-test.sh prod` pass;
- every Argo CD app is `Synced/Healthy`;
- no alerts in Prometheus `/alerts`;
- the `boutique/frontend:1.1.0` image is **already built** (`build-frontend.sh 1.1.0`), if you want to skip the live build wait.

---

### 1. Repository and layout (3 min)

```bash
git clone https://github.com/<user>/microservices-demo.git && cd microservices-demo
tree -L 3 platform docs/challenge
git diff --stat <first-upstream-commit>..HEAD -- src/    # code changes: 4 frontend files
```

Message: *"I did not rewrite the app. I reused the upstream Kustomize and added a platform layer on top."* Show `platform/deploy/base/kustomization.yaml`: the upstream base, the upstream NetworkPolicy component, the patches.

### 2. Building the application image (4 min)

```bash
sed -n '/Challenge/,/^}/p' src/frontend/main.go          # what changed in the code
platform/scripts/build-frontend.sh 1.1.0                  # docker build + kind load
docker run --rm -p 18080:8080 -p 19090:9090 -e PORT=8080 \
  -e PRODUCT_CATALOG_SERVICE_ADDR=x:1 -e CURRENCY_SERVICE_ADDR=x:1 -e CART_SERVICE_ADDR=x:1 \
  -e RECOMMENDATION_SERVICE_ADDR=x:1 -e SHIPPING_SERVICE_ADDR=x:1 -e CHECKOUT_SERVICE_ADDR=x:1 \
  -e AD_SERVICE_ADDR=x:1 -e SHOPPING_ASSISTANT_SERVICE_ADDR=x:1 boutique/frontend:1.1.0 &
sleep 2; curl -s localhost:18080/_healthz; curl -s localhost:19090/metrics | grep build_info; kill %1
```

Message: the image also runs on its own. The `*_ADDR` variables are mandatory: the process panics if one is missing, a common configuration error. Then show CI in GitHub Actions: the same Dockerfile, Trivy, push to GHCR.

### 3. Installing on Kubernetes (3 min, already done)

```bash
sed -n '1,20p' platform/scripts/bootstrap.sh              # what it does, idempotent
kubectl get ns
kubectl -n argocd get applications
```

Argo CD UI: the resource tree of `boutique-prod`. Message: *"After bootstrap, the only way to change the cluster is Git."*

### 4. Pods, services, gateway, configuration (4 min)

```bash
kubectl -n boutique-prod get deploy,pods,svc,hpa,pdb
kubectl -n gateway-infra get gateway; kubectl -n boutique-prod get httproute
kubectl -n boutique-prod get networkpolicy
kubectl -n boutique-prod describe deploy cartservice | grep -A3 REDIS_ADDR    # from a Secret, value not shown
kubectl get ns boutique-prod --show-labels                                     # PSA restricted
platform/scripts/rbac-check.sh
```

### 5. Main application endpoints (3 min)

In the browser: home → product → cart → checkout. Then the automated equivalent:

```bash
platform/scripts/smoke-test.sh prod
```

### 6. Health checks, readiness, logs, metrics (5 min)

```bash
kubectl -n boutique-prod get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | jq
kubectl -n boutique-prod logs deploy/frontend --since=2m | jq -c 'select(."http.req.path"=="/cart/checkout")' | tail -2
kubectl -n boutique-prod port-forward svc/frontend-metrics 19090:9090 & curl -s localhost:19090/metrics | grep -E 'checkout|build_info'; kill %1
kubectl top pods -n boutique-prod
```

Grafana, dashboard with environment `boutique-prod`: requests by route, p95 latency, orders per minute, running version. Prometheus `/alerts`: the 8 rules, all inactive.

### 7. Update and rollout (5 min)

```bash
platform/scripts/release.sh dev 1.1.0           # commit + push + sync + rollout
# T2: a new pod is ready before the old one is removed (maxUnavailable 0)
curl -sI http://dev.boutique.local/ | grep -i x-app-version     # 1.1.0
SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0             # promote the same image
```

Grafana: the "Frontend version(s) running" panel shows 1.0.0 and 1.1.0 side by side for a few seconds, then only 1.1.0. Argo CD: the app History with the commit SHA.

### 8. Failure scenario and troubleshooting (8 min)

The most instructive scenario is `netpol-typo`: every pod stays green, but orders fail.

```bash
platform/scripts/chaos.sh netpol-typo dev
# in the browser: an order on dev.boutique.local fails (or: smoke-test.sh dev -> checkout FAIL)
```

Live diagnosis, following [runbook §2.2](runbook.md#rb-checkout):

1. `kubectl -n boutique-dev get pods` → everything Running and Ready: *"it is not a pod problem"*.
2. Grafana or the metric: 5xx only on `/cart/checkout` → *"the problem is in a checkout backend"*.
3. `kubectl -n boutique-dev logs deploy/checkoutservice --since=5m` → error towards payment.
4. `kubectl -n argocd get app boutique-dev` → **OutOfSync**: someone changed the cluster.
5. `kubectl -n boutique-dev get networkpolicy paymentservice -o jsonpath='{.spec.ingress}'` → `checkout-service` instead of `checkoutservice`.
6. **Use of AI (point 11)**: paste the symptom and outputs into Claude Code with the prompt from [ai-usage §4](ai-usage.md#4-troubleshooting-case-with-ai). Compare the hypotheses it proposes with the ones made by hand.

```bash
platform/scripts/chaos.sh restore dev          # sync from Git
platform/scripts/smoke-test.sh dev
```

Self-heal bonus: run `chaos.sh bad-image prod`. Argo CD puts the right image back on its own within a minute (`kubectl -n argocd get app boutique-prod -w`).

### 9. Rollback (4 min)

```bash
platform/scripts/rollback.sh prod              # git revert of the 1.1.0 release -> sync -> rollout
curl -sI http://boutique.local/ | grep -i x-app-version     # 1.0.0
git log --oneline -3
```

Explain:
- the difference from `rollback.sh prod --emergency`;
- why, in prod, `kubectl rollout undo` on its own gets undone by self-heal ([runbook §3](runbook.md#3-rollback)).

### 10. Krateo (5 min)

Slides or the document [krateo.md](krateo.md): §3 (parameters), §4 (diagram), §7 (recommendation). If the PoC is installed:

```bash
cat platform/krateo/krateo/composition-example.yaml
platform/scripts/krateo-poc.sh status
kubectl get boutiqueservices -A
```

Message: *"The golden path already exists: it is my overlays. Krateo turns them into a self-service API. I would not adopt it right away; I would run a pilot once there are more teams."*

### 11. A concrete example of AI use (3 min)

Besides step 8.6, show [ai-usage.md §3](ai-usage.md#3-ai-mistakes-caught-by-verification). The best story to tell is the **JSON patch with the wrong index**: `kustomize build` passed, but the patch changed `RATE` instead of `USERS`. It only surfaced by reading the rendered output.

---

**After the demo**: run `platform/scripts/release.sh dev 1.0.0` to bring dev back to its initial state, if you need to repeat the demo.

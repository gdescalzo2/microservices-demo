# Copione della demo (circa 45 minuti)

Ogni passo corrisponde a un punto obbligatorio della challenge (§7). **Preparazione**: cluster già avviato con `bootstrap.sh` (la prima installazione richiede 15–25 minuti e non va fatta dal vivo). Tenere aperti 4 terminali e 3 tab del browser.

| Terminale | Contenuto |
|---|---|
| T1 | comandi della demo (root del repo) |
| T2 | `k9s` oppure `watch kubectl -n boutique-dev get pods` |
| T3 | `kubectl -n argocd port-forward svc/argocd-server 8080:80` |
| T4 | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` (+ Prometheus su 9090 se serve) |

| Browser | URL |
|---|---|
| Negozio | http://dev.boutique.local e http://boutique.local |
| Argo CD | http://localhost:8080 (app `boutique-dev`, `boutique-prod`, `platform-config`) |
| Grafana | http://localhost:3000 → dashboard **Online Boutique - Overview** |

**Pre-flight (5 minuti prima)**: `smoke-test.sh dev && smoke-test.sh prod`, tutte le app Argo CD `Synced/Healthy`, nessun alert in Prometheus `/alerts`, immagine `boutique/frontend:1.1.0` **già compilata** (`build-frontend.sh 1.1.0`) se si vuole evitare l'attesa della build dal vivo.

---

### 1. Repository e struttura (3 min)

```bash
git clone https://github.com/<utente>/microservices-demo.git && cd microservices-demo
tree -L 3 platform docs/challenge
git diff --stat <primo-commit-upstream>..HEAD -- src/    # modifiche al codice: 4 file del frontend
```

Messaggio: *"Non ho riscritto l'app. Ho riusato il Kustomize upstream e aggiunto un livello di piattaforma."* Mostrare `platform/deploy/base/kustomization.yaml`: base upstream, componente NetworkPolicy upstream, patch.

### 2. Build dell'immagine applicativa (4 min)

```bash
sed -n '/Challenge/,/^}/p' src/frontend/main.go          # cosa è cambiato nel codice
platform/scripts/build-frontend.sh 1.1.0                  # docker build + kind load
docker run --rm -p 18080:8080 -p 19090:9090 -e PORT=8080 \
  -e PRODUCT_CATALOG_SERVICE_ADDR=x:1 -e CURRENCY_SERVICE_ADDR=x:1 -e CART_SERVICE_ADDR=x:1 \
  -e RECOMMENDATION_SERVICE_ADDR=x:1 -e SHIPPING_SERVICE_ADDR=x:1 -e CHECKOUT_SERVICE_ADDR=x:1 \
  -e AD_SERVICE_ADDR=x:1 -e SHOPPING_ASSISTANT_SERVICE_ADDR=x:1 boutique/frontend:1.1.0 &
sleep 2; curl -s localhost:18080/_healthz; curl -s localhost:19090/metrics | grep build_info; kill %1
```

Messaggio: l'immagine gira anche da sola. Le variabili `*_ADDR` sono obbligatorie (il processo va in panic se mancano, un errore di configurazione comune). Mostrare la CI in GitHub Actions: stesso Dockerfile, Trivy, push su GHCR.

### 3. Installazione su Kubernetes (3 min, già fatta)

```bash
sed -n '1,20p' platform/scripts/bootstrap.sh              # cosa fa, idempotente
kubectl get ns
kubectl -n argocd get applications
```

UI di Argo CD: albero delle risorse di `boutique-prod`. Messaggio: *"Dopo il bootstrap, l'unico modo di cambiare il cluster è Git."*

### 4. Pod, service, gateway, configurazioni (4 min)

```bash
kubectl -n boutique-prod get deploy,pods,svc,hpa,pdb
kubectl -n gateway-infra get gateway; kubectl -n boutique-prod get httproute
kubectl -n boutique-prod get networkpolicy
kubectl -n boutique-prod describe deploy cartservice | grep -A3 REDIS_ADDR    # da Secret, valore non visibile
kubectl get ns boutique-prod --show-labels                                     # PSA restricted
platform/scripts/rbac-check.sh
```

### 5. Endpoint applicativi principali (3 min)

Nel browser: home → prodotto → carrello → checkout. Poi l'equivalente automatico:

```bash
platform/scripts/smoke-test.sh prod
```

### 6. Health check, readiness, log, metriche (5 min)

```bash
kubectl -n boutique-prod get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | jq
kubectl -n boutique-prod logs deploy/frontend --since=2m | jq -c 'select(."http.req.path"=="/cart/checkout")' | tail -2
kubectl -n boutique-prod port-forward svc/frontend-metrics 19090:9090 & curl -s localhost:19090/metrics | grep -E 'checkout|build_info'; kill %1
kubectl top pods -n boutique-prod
```

Grafana: dashboard, ambiente `boutique-prod`: richieste per route, latenza p95, ordini al minuto, versione in esecuzione. Prometheus `/alerts`: le 8 regole, tutte inattive.

### 7. Aggiornamento e rollout (5 min)

```bash
platform/scripts/release.sh dev 1.1.0           # commit + push + sync + rollout
# T2: un pod nuovo pronto prima che il vecchio venga tolto (maxUnavailable 0)
curl -sI http://dev.boutique.local/ | grep -i x-app-version     # 1.1.0
SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0             # promozione della stessa immagine
```

Grafana: il pannello "Frontend version(s) running" mostra per qualche secondo 1.0.0 e 1.1.0 insieme, poi solo 1.1.0. Argo CD: History della app con lo SHA del commit.

### 8. Failure scenario e troubleshooting (8 min)

Lo scenario più istruttivo: `netpol-typo`. Tutti i pod restano verdi, ma gli ordini falliscono.

```bash
platform/scripts/chaos.sh netpol-typo dev
# nel browser: un ordine su dev.boutique.local fallisce (o: smoke-test.sh dev -> checkout FAIL)
```

Diagnosi dal vivo, seguendo il [runbook §2.2](runbook.md#rb-checkout):

1. `kubectl -n boutique-dev get pods` → tutto Running e Ready: *"non è un problema di pod"*
2. Grafana o metrica: 5xx solo su `/cart/checkout` → *"il problema è in un backend del checkout"*
3. `kubectl -n boutique-dev logs deploy/checkoutservice --since=5m` → errore verso payment
4. `kubectl -n argocd get app boutique-dev` → **OutOfSync**: qualcuno ha cambiato il cluster
5. `kubectl -n boutique-dev get networkpolicy paymentservice -o jsonpath='{.spec.ingress}'` → `checkout-service` invece di `checkoutservice`
6. **Uso dell'AI (punto 11)**: incollare sintomo e output in Claude Code con il prompt di [ai-usage §4](ai-usage.md#4-caso-di-troubleshooting-con-lai) e confrontare le ipotesi proposte con quelle fatte a mano.

```bash
platform/scripts/chaos.sh restore dev          # sync da Git
platform/scripts/smoke-test.sh dev
```

Bonus self-heal: `chaos.sh bad-image prod` → Argo CD riporta l'immagine giusta da solo entro un minuto (`kubectl -n argocd get app boutique-prod -w`).

### 9. Rollback (4 min)

```bash
platform/scripts/rollback.sh prod              # git revert del rilascio 1.1.0 -> sync -> rollout
curl -sI http://boutique.local/ | grep -i x-app-version     # 1.0.0
git log --oneline -3
```

Spiegare la differenza con `rollback.sh prod --emergency` e perché in prod `kubectl rollout undo` da solo viene annullato dal self-heal ([runbook §3](runbook.md#3-rollback)).

### 10. Krateo (5 min)

Slide o documento: [krateo.md](krateo.md) §3 (parametri), §4 (diagramma), §7 (raccomandazione). Se la PoC è installata:

```bash
cat platform/krateo/krateo/composition-example.yaml
platform/scripts/krateo-poc.sh status
kubectl get boutiqueservices -A
```

Messaggio: *"Il golden path c'è già, sono i miei overlay. Krateo li trasforma in un'API self-service. Non lo adotterei subito: lo porterei in un pilota quando ci saranno più team."*

### 11. Esempio concreto di uso dell'AI (3 min)

Oltre al passo 8.6, mostrare [ai-usage.md §3](ai-usage.md#3-errori-dellai-intercettati-dalle-verifiche). Il caso migliore da raccontare è la **patch JSON con indice sbagliato**: `kustomize build` passava, ma la patch modificava `RATE` invece di `USERS`. È emerso solo leggendo l'output renderizzato.

---

**Dopo la demo**: `platform/scripts/release.sh dev 1.0.0` per riportare dev allo stato iniziale, se serve ripetere.

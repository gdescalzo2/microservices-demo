# Runbook operativo

Per chi è di turno su Online Boutique. Ogni alert Prometheus punta a una sezione di questo documento (`runbook_url`). Tutti i comandi assumono il contesto `kind-boutique`, l'ambiente in `$NS` e l'app Argo CD in `$APP`:

```bash
export NS=boutique-dev APP=boutique-dev        # oppure boutique-prod
alias k=kubectl
```

## 0. Metodo

Prima capire, poi cambiare. L'ordine:

1. **Sintomo**: cosa vede l'utente o quale alert scatta? Da quando?
2. **Perimetro**: un ambiente o entrambi? Una route o tutte? Un pod o tutte le repliche? È cambiato qualcosa (rilascio, sync Argo CD, deriva manuale)?
3. **Ipotesi**: al massimo 2 o 3, ordinate per probabilità ed economicità della verifica.
4. **Evidenza**: eventi → stato dei pod → log → metriche → configurazione. Per ogni ipotesi, il comando che la conferma o la scarta.
5. **Mitigazione**: prima ripristinare il servizio (rollback, sync da Git, scale), poi la correzione definitiva via Git.
6. **Verifica**: smoke test, metriche tornate normali, alert risolto.
7. **Chiusura**: cosa è successo, perché non l'abbiamo visto prima, cosa cambiamo (alert, test, policy).

**Domanda chiave in un sistema GitOps**: *il cluster è uguale a Git?* `kubectl -n argocd get app` mostra subito se c'è deriva (`OutOfSync`) o un sync fallito.

**Quando fare escalation** (al platform team o allo sviluppo):
- il problema riguarda componenti condivisi (Gateway, Argo CD, Kyverno, nodo, DNS), cioè più namespace o tutti i servizi;
- la correzione richiede un cambio di codice o di policy;
- il rollback non risolve: il problema non è nell'ultimo rilascio;
- c'è rischio di perdita dati o di sicurezza (Secret esposto, accesso anomalo).

Insieme all'escalation vanno passati: sintomo, orario d'inizio, ambiente, cosa è stato verificato ed escluso, cosa è stato già tentato.

## 1. Verifica dello stato (checklist)

```bash
# GitOps: il cluster è allineato?
k -n argocd get applications
#   SYNC = Synced, HEALTH = Healthy per platform-config, boutique-dev, boutique-prod

# Workload
k -n $NS get deploy                       # READY = desiderati/disponibili
k -n $NS get pods -o wide                 # STATUS, RESTARTS, nodo
k -n $NS get events --sort-by=.lastTimestamp | tail -20

# Rete ed esposizione
k -n gateway-infra get gateway boutique-gateway       # PROGRAMMED=True, ADDRESS valorizzato
k -n $NS get httproute frontend -o jsonpath='{.status.parents[0].conditions}' | jq
k -n $NS get svc,endpointslices               # ogni Service con endpoint pronti

# Configurazione
k -n $NS get secret redis-auth                 # deve esistere (non mostrarne il contenuto)
k -n $NS describe deploy frontend | sed -n '/Environment/,/Mounts/p'

# Funzionale
platform/scripts/smoke-test.sh dev
```

Health check disponibili:

| Servizio | Liveness / readiness | Note |
|---|---|---|
| frontend | HTTP `GET /_healthz` (porta 8080) + startup probe | statico, non verifica i backend |
| servizi gRPC | `grpc` probe nativa Kubernetes (gRPC health protocol) | |
| redis-cart | TCP 6379 | |
| loadgenerator | nessuna | eccezione nota (client di carico), segnalata da Kyverno in audit |

```bash
# provare un health check a mano
k -n $NS port-forward deploy/frontend 8080:8080 & curl -s localhost:8080/_healthz; kill %1
k -n $NS get pods -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
```

Log (tutti in JSON su stdout):

```bash
k -n $NS logs deploy/frontend --since=10m | jq -r 'select(.severity!="debug") | [.timestamp,.severity,."http.req.path",."http.resp.status",.message] | @tsv' | tail
k -n $NS logs deploy/checkoutservice --since=10m | tail -20
k -n $NS logs deploy/frontend --previous      # log del container prima dell'ultimo restart
```

Metriche (Prometheus: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`):

```promql
sum by (route, code) (rate(boutique_frontend_http_requests_total{namespace="boutique-prod"}[5m]))
histogram_quantile(0.95, sum by (le, route) (rate(boutique_frontend_http_request_duration_seconds_bucket{namespace="boutique-prod"}[5m])))
count by (version) (boutique_frontend_build_info{namespace="boutique-prod"})
```

## 2. Troubleshooting per sintomo

<a id="rb-frontend-errors"></a>
### 2.1 Il frontend restituisce 5xx (`BoutiqueFrontendHighErrorRate`)

1. **Quale route?** Dashboard "Errors by route and code", oppure:
   `sum by (route, code) (rate(boutique_frontend_http_requests_total{namespace="$NS",code=~"5.."}[5m]))`
2. La route individua il backend: `/` → catalog, currency, ad, recommendation, cart; `/product/{id}` → catalog, currency, recommendation, ad; `/cart` → cart (e quindi Redis), shipping; `/cart/checkout` → [§2.2](#rb-checkout).
3. Nei log del frontend il messaggio d'errore contiene il servizio e il codice gRPC:
   `k -n $NS logs deploy/frontend --since=10m | grep -i '"severity":"error"' | tail -5`
   - `Unavailable` / `connection refused` → il backend non ha endpoint: `k -n $NS get endpointslices -l kubernetes.io/service-name=<svc>`
   - `DeadlineExceeded` → backend lento o bloccato da una NetworkPolicy (i pacchetti scartati vanno in timeout, non in errore immediato)
   - `Unauthenticated` / `NOAUTH` (cartservice) → password Redis non allineata, [§2.8](#rb-secret)
4. Correlare con i cambiamenti recenti: `k -n argocd get app $APP -o jsonpath='{.status.history}' | jq '.[-3:]'`, `git log -5 -- platform/`.

<a id="rb-checkout"></a>
### 2.2 Gli ordini falliscono (`BoutiqueCheckoutFailing`)

Il checkout chiama cart, catalog, currency, shipping e payment (gli errori di email e di svuotamento carrello sono tollerati).

```bash
k -n $NS logs deploy/checkoutservice --since=10m | grep -iE 'error|fail|warn' | tail
#   "failed to charge card"  -> paymentservice
#   "shipping error"         -> shippingservice
#   "failed to get user cart"/"cart failure" -> cartservice / redis
k -n $NS get pods -l 'app in (paymentservice,shippingservice,cartservice,redis-cart)'
k -n $NS get networkpolicy                                   # qualcuna cambiata di recente?
k -n argocd get app $APP                                      # OutOfSync = qualcuno ha toccato il cluster
```

Se i pod sono tutti `Running`/`Ready` ma le chiamate vanno in timeout, la prima ipotesi è la **rete**: NetworkPolicy, oppure un Service con selector sbagliato.

```bash
k -n $NS get networkpolicy paymentservice -o jsonpath='{.spec.ingress}' | jq
k -n $NS get pods -l app=checkoutservice --show-labels     # il label reale da consentire
# prova di connettività dal pod di checkout (immagine distroless: niente shell, usare un pod di debug):
k -n $NS debug -it deploy/checkoutservice --image=busybox:1.38.0 --target=server -- nc -zvw3 paymentservice 50051
```

> Nota: `kubectl debug` crea un container effimero che PSA `restricted` può rifiutare. In quel caso usare la `--profile=restricted` (kubectl ≥ 1.30) o fare la verifica da un pod temporaneo con label `app=checkoutservice` in dev.

Mitigazione: dev → `platform/scripts/chaos.sh restore dev` (sync da Git). Prod → il self-heal di Argo CD riallinea da solo. Se il guasto viene da Git, `rollback.sh prod`.

<a id="rb-latency"></a>
### 2.3 Latenza alta (`BoutiqueFrontendLatencyHigh`)

1. Su tutte le route o su una? Pannello "p95 latency by route".
2. CPU throttling? Il limite di CPU del frontend è 200m:
   `sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="$NS"}[5m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="$NS"}[5m]))`
3. Il nodo è saturo? `kubectl top node`, `kubectl top pods -n $NS --sort-by=cpu`
4. HPA (prod): `k -n boutique-prod get hpa frontend`. È al massimo delle repliche? `TARGETS` mostra `<unknown>`? Allora metrics-server non risponde.

<a id="rb-metrics-down"></a>
### 2.4 Prometheus non legge le metriche del frontend (`BoutiqueFrontendMetricsDown`)

```bash
k -n $NS get servicemonitor frontend
k -n $NS get endpointslices -l kubernetes.io/service-name=frontend-metrics
# Prometheus UI -> Status -> Targets -> "serviceMonitor/$NS/frontend/0": errore mostrato
k -n $NS port-forward svc/frontend-metrics 19090:9090 & curl -s localhost:19090/metrics | head; kill %1
```

Cause tipiche: frontend non pronto (non ci sono endpoint), porta `metrics` rinominata, oppure NetworkPolicy che blocca il namespace `monitoring`.

<a id="rb-pod-waiting"></a>
### 2.5 Pod bloccato: ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError (`BoutiqueContainerWaiting`, `BoutiquePodRestarting`)

```bash
k -n $NS get pods | grep -v Running
k -n $NS describe pod <pod> | sed -n '/State:/,/Ready:/p;/Events:/,$p'
```

| Reason | Significato | Cosa controllare |
|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | immagine o tag inesistente, registry irraggiungibile, credenziali | `describe` → messaggio del pull; tag nell'overlay; in kind: `docker exec boutique-control-plane crictl images \| grep frontend` |
| `CrashLoopBackOff` | il processo esce subito | `k logs <pod> --previous`; exit code in `Last State` (137 = OOM o SIGKILL, 1/2 = errore applicativo, ad esempio una variabile d'ambiente mancante) |
| `CreateContainerConfigError` | Secret o ConfigMap referenziato mancante | `describe` → "secret \"redis-auth\" not found" → [§2.8](#rb-secret) |
| `RunContainerError` / `CreateContainerError` | vincoli di sicurezza o runtime | `describe`; ad esempio `readOnlyRootFilesystem` con un'app che scrive su disco |

<a id="rb-oom"></a>
### 2.6 OOMKilled (`BoutiqueContainerOOMKilled`)

```bash
k -n $NS describe pod -l app=<svc> | grep -A5 'Last State'        # Reason: OOMKilled, Exit Code: 137
k -n $NS get deploy <svc> -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq
```

PromQL: consumo reale rispetto al limite.

```promql
max by (pod) (container_memory_working_set_bytes{namespace="$NS",container="server"})
  / on (pod) group_left max by (pod) (kube_pod_container_resource_limits{namespace="$NS",resource="memory"})
```

Il limite è sottodimensionato o c'è un leak? Se il working set cresce in modo continuo fino al limite, è un leak: escalation allo sviluppo. Se c'è un picco su un carico normale, il limite è troppo basso: correggerlo **in Git** (patch nell'overlay), mai solo con `kubectl set resources`, perché verrebbe annullato (prod) o resterebbe come deriva (dev).

<a id="rb-rollout-stuck"></a>
### 2.7 Rollout bloccato (`BoutiqueDeploymentReplicasMismatch`)

```bash
k -n $NS rollout status deploy/frontend --timeout=10s
k -n $NS get rs -l app=frontend            # vecchio RS ancora attivo, nuovo RS con pod non pronti
k -n $NS rollout history deploy/frontend
```

Con `maxUnavailable: 0` un rollout fallito **non riduce la capacità**: i pod vecchi restano in servizio e il nuovo pod resta in errore. Il negozio funziona e il problema è solo che la nuova versione non entra. Dopo `progressDeadlineSeconds` (600 s) il Deployment segna `Progressing=False` e Argo CD mostra l'app come `Degraded`. Azione: [rollback](#3-rollback).

<a id="rb-secret"></a>
### 2.8 Secret mancante o password Redis errata

```bash
k -n $NS get secret redis-auth || platform/scripts/create-secrets.sh $NS
k -n $NS logs deploy/cartservice --since=10m | grep -iE 'redis|auth' | tail -5
k -n $NS logs deploy/redis-cart --since=10m | tail -5
```

Le variabili d'ambiente si leggono all'avvio: dopo aver creato o ruotato il Secret, riavviare Redis e cartservice (`create-secrets.sh --rotate` lo fa da solo).

### 2.9 Argo CD: OutOfSync, Degraded, sync fallito

```bash
k -n argocd get app $APP -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
k -n argocd get app $APP -o jsonpath='{.status.operationState.message}{"\n"}'
k -n argocd get app $APP -o json | jq '.status.resources[] | select(.status!="Synced" or .health.status!="Healthy") | {kind,name,status,health:.health.status,msg:.health.message}'
argocd app diff $APP          # con la CLI (dopo argocd login)
```

| Messaggio | Causa |
|---|---|
| `admission webhook "validate.kyverno.svc-fail" denied the request` | La modifica viola una policy Enforce (tag `:latest`, label owner mancante). Correggere il manifest in Git |
| `pods ... is forbidden: violates PodSecurity "restricted"` | Il container non rispetta PSA restricted (root, capability, seccomp) |
| `resource ... is not permitted in project` | L'AppProject non consente quella risorsa o quel namespace (guardrail funzionante) |
| `OutOfSync` senza errori | Deriva manuale (dev) oppure nuovo commit non ancora sincronizzato: `argocd_sync` o attendere il polling (60 s) |

### 2.10 Il sito non risponde (nessun pod in errore)

```bash
k -n gateway-infra get gateway boutique-gateway -o wide     # ADDRESS vuoto?
docker ps --filter name=cloud-provider-kind                  # il controller sul host è attivo?
docker logs cloud-provider-kind --tail 30
getent hosts dev.boutique.local                              # /etc/hosts punta all'IP attuale del Gateway?
curl -sv --resolve dev.boutique.local:80:$(k -n gateway-infra get gateway boutique-gateway -o jsonpath='{.status.addresses[0].value}') http://dev.boutique.local/_healthz
k -n $NS get httproute frontend -o jsonpath='{.status}' | jq   # Accepted / ResolvedRefs
```

Un `404` dal Gateway (e non dal frontend) significa che nessuna HTTPRoute corrisponde all'host. Cause tipiche: hostname sbagliato, oppure namespace senza il label `platform.example.com/gateway-access=true`.

## 3. Rollback

| Situazione | Comando | Note |
|---|---|---|
| Rilascio difettoso, Git disponibile (**default**) | `platform/scripts/rollback.sh <env>` | `git revert` dell'ultimo commit sull'overlay → push → sync. Tracciato e revisionabile |
| Emergenza, Git o CI non disponibili | `platform/scripts/rollback.sh <env> --emergency` | `kubectl rollout undo`; in prod sospende prima l'auto-sync. **Poi riallineare Git** e riattivare l'auto-sync |
| Dalla UI di Argo CD | App → History and rollback → versione precedente | Disattiva l'auto-sync dell'app: va riattivato dopo aver corretto Git |
| Deriva manuale (solo dev) | `platform/scripts/chaos.sh restore dev` | Sync da Git, annulla le modifiche fatte con kubectl |

Perché il default è `git revert` e non `kubectl rollout undo`: in prod il self-heal di Argo CD riporterebbe il cluster allo stato di Git (la versione rotta) entro circa un minuto. Il rollback "vero" deve passare dalla fonte di verità.

Verifica dopo il rollback:

```bash
k -n $NS rollout status deploy/frontend
curl -sI http://boutique.local/ | grep -i x-app-version
platform/scripts/smoke-test.sh prod
```

In Grafana il pannello "Frontend version(s) running" mostra il passaggio di versione.

## 4. Scenari di guasto riproducibili

`platform/scripts/chaos.sh <scenario> [dev|prod]`. Ogni scenario ha sintomo, diagnosi e ripristino:

| Scenario | Sintomo | Come si diagnostica | Ripristino |
|---|---|---|---|
| `bad-image` | rollout bloccato, sito **ancora funzionante** | `rollout status` in stallo, pod nuovo `ImagePullBackOff`, alert `ContainerWaiting` | `chaos.sh restore` (dev) / `rollback.sh` |
| `netpol-typo` | solo il checkout fallisce (500), tutto il resto OK, **pod tutti Ready** | metrica 5xx su `/cart/checkout`, log del frontend "failed to charge card" + timeout, NetworkPolicy con label sbagliato | `chaos.sh restore` |
| `oom` | raccomandazioni vuote o errori sulla pagina prodotto, restart continui | `OOMKilled`, exit 137, limite 32Mi | `chaos.sh restore` |
| `redis-down` | carrello e checkout falliscono | Service `redis-cart` senza endpoint, errori nei log di cartservice | `chaos.sh restore` (le repliche sono dichiarate in Git, quindi Argo CD vede la deriva) |

In prod gli stessi scenari mostrano il **self-heal**: Argo CD rileva la deriva e la annulla da solo (`k -n argocd get app boutique-prod -w`).

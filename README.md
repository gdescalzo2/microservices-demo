# Online Boutique come servizio di piattaforma — Challenge L2

Fork di [GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo) (Online Boutique) portato a un livello di rilascio, esercizio e demo su Kubernetes: due ambienti (dev/prod), GitOps con Argo CD, Gateway API, osservabilità con Prometheus/Grafana, sicurezza minima (Secret, RBAC, Pod Security, NetworkPolicy, Kyverno), runbook, scenari di guasto riproducibili e una PoC Krateo per esporre il servizio in self-service.

Il README originale del progetto è in [README.upstream.md](README.upstream.md).

| Documento | Contenuto |
|---|---|
| [docs/challenge/architecture.md](docs/challenge/architecture.md) | Architettura applicativa e di piattaforma, flussi, scelte e trade-off |
| [docs/challenge/runbook.md](docs/challenge/runbook.md) | Verifica, troubleshooting per sintomo, rollback |
| [docs/challenge/security.md](docs/challenge/security.md) | Secret, RBAC, policy, supply chain, limiti residui |
| [docs/challenge/krateo.md](docs/challenge/krateo.md) | Valutazione Krateo, blueprint e PoC |
| [docs/challenge/ai-usage.md](docs/challenge/ai-usage.md) | Come è stata usata l'AI, cosa è stato verificato e scartato |
| [docs/challenge/demo.md](docs/challenge/demo.md) | Copione della demo end-to-end (11 passi richiesti) |

---

## 1. Perché Online Boutique

**Dominio.** È un e-commerce dimostrativo: catalogo, carrello, conversione valuta, checkout con pagamento e spedizione simulati, email di conferma, raccomandazioni e banner pubblicitari. Un generatore di carico (Locust) simula gli utenti.

**Perché è adatta a una challenge L2:**

| Criterio | Online Boutique |
|---|---|
| Complessità | 11 microservizi + Redis, 5 linguaggi (Go, C#, Node.js, Python, Java) |
| Pertinenza cloud-native | Progettata per Kubernetes, comunicazione interna gRPC, frontend HTTP, servizi stateless + uno stateful |
| Manifest disponibili | Kustomize base + componenti, Helm chart, manifest "release" |
| Osservabilità | Log JSON strutturati e probe gRPC/HTTP già presenti; **nessuna metrica Prometheus** (lacuna colmata qui) |
| Idoneità alla demo | UI visibile, flusso d'acquisto end-to-end testabile con curl, carico generato in automatico |
| Scenari di guasto realistici | Catena di dipendenze lunga (checkout chiama 6 servizi): un guasto in profondità produce sintomi in superficie, ideale per il troubleshooting |

Alternative considerate: *Sock Shop* (Weaveworks, non più mantenuto) e *OpenTelemetry Demo* (più completo sull'osservabilità, ma circa il doppio dei componenti, troppo pesante per una VM con 10 GB di RAM).

**Parti usate nella challenge:** tutti i servizi del Kustomize base upstream (`kustomize/base`), il componente upstream `network-policies` e il codice del **frontend** (modificato). Non usati: il servizio `shoppingassistantservice` (richiede Gemini/AlloyDB su GCP), i componenti GCP (Spanner, Memorystore, Cloud Operations), Terraform e i manifest Istio.

## 2. Cosa è stato aggiunto o modificato rispetto all'upstream

| Area | Modifica | Dove |
|---|---|---|
| Codice | Frontend: metriche Prometheus su porta dedicata `9090` (richieste per route/codice, istogramma latenza, `build_info` con versione), header `X-App-Version`, versione iniettata in build. Test unitari. | `src/frontend/metrics.go`, `metrics_test.go`, `main.go`, `Dockerfile` |
| Packaging | Base di piattaforma sopra il Kustomize upstream + overlay `dev`/`prod` + componenti | `platform/deploy/` |
| Esposizione | Gateway API (Gateway condiviso + HTTPRoute per ambiente) al posto del Service LoadBalancer | `platform/addons/config/gateway/`, `overlays/*/httproute.yaml` |
| Sicurezza | Redis con password da Secret (non in Git), ServiceAccount dedicato anche a Redis, nessun token API montato, seccomp, PSA `restricted`, RBAC per persona, policy Kyverno | `platform/deploy/base/patches/`, `overlays/*/rbac.yaml`, `platform/addons/config/policies/` |
| GitOps | Argo CD: AppProject con guardrail, 3 Application (platform-config, dev, prod) | `platform/gitops/` |
| Osservabilità | ServiceMonitor, 8 regole di alert con link al runbook, dashboard Grafana | `platform/deploy/components/observability/`, `platform/addons/config/monitoring/` |
| CI | Lint, render + validazione schema, guard "no Secret in Git", test Go, build immagine + Trivy, push su GHCR. Action pinnate a SHA. | `.github/workflows/platform-ci.yaml` |
| Operatività | Bootstrap idempotente, smoke test end-to-end, release/rollback GitOps, scenari di guasto, verifica RBAC | `platform/scripts/` |
| Krateo | Chart "golden path" con `values.schema.json`, CompositionDefinition, PoC con core-provider | `platform/krateo/`, `platform/scripts/krateo-poc.sh` |
| Pulizia | Rimossi i workflow upstream che richiedono il progetto GCP di Google (`ci-main`, `ci-pr`, `deploy-pr`, `cleanup`, `make-release`) | `.github/workflows/` |

Il diff con l'upstream è tutto in `platform/`, `docs/challenge/`, `src/frontend/` (4 file) e `.github/workflows/`: `git diff upstream/main --stat`.

## 3. Struttura del repository (parti nuove)

```
platform/
├── kind/cluster.yaml                 # cluster locale (nodo singolo)
├── deploy/
│   ├── base/                         # = kustomize/base upstream + patch di piattaforma
│   ├── components/
│   │   ├── kind-sizing/              # CPU request ridotte per il laptop
│   │   └── observability/            # ServiceMonitor
│   └── overlays/{dev,prod}/          # namespace, HTTPRoute, RBAC, HPA/PDB (prod), versione frontend
├── addons/
│   ├── values/                       # values Helm: metrics-server, kube-prometheus-stack, kyverno, argo-cd
│   └── config/                       # Gateway, alert, dashboard, policy (sincronizzati da Argo CD)
├── gitops/                           # AppProject + Application Argo CD
├── krateo/                           # golden path: chart + CompositionDefinition + esempi
└── scripts/                          # bootstrap, build, smoke test, release, rollback, chaos, rbac, krateo
docs/challenge/                       # documentazione della challenge
```

## 4. Prerequisiti

VM o host Linux (riferimento: Ubuntu 26.04 LTS su VMware Workstation) con **4 vCPU, 10 GB di RAM, 60 GB di disco**.

1. **Docker Engine** (non Docker Desktop):
   ```bash
   # repository ufficiale Docker (https://docs.docker.com/engine/install/ubuntu/);
   # se non supporta ancora la release Ubuntu in uso: sudo apt install docker.io
   sudo usermod -aG docker "$USER"   # poi logout/login
   ```
2. **Limiti inotify** (altrimenti kind fallisce con "too many open files"):
   ```bash
   echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512" | sudo tee /etc/sysctl.d/99-kind.conf
   sudo sysctl --system
   ```
3. **Utility**: `sudo apt install -y git curl jq openssl`
4. **CLI** (kind, kubectl, helm, kustomize, kubeconform, argocd, k9s) in `~/.local/bin`, senza sudo:
   ```bash
   platform/scripts/install-tools.sh
   ```
5. **Fork pubblico** di questo repository su GitHub: Argo CD legge da lì.

## 5. Installazione

```bash
git clone https://github.com/<tuo-utente>/microservices-demo.git && cd microservices-demo
platform/scripts/set-github-user.sh <tuo-utente>   # sostituisce il placeholder YOUR_GITHUB_USER
git commit -am "chore: point platform to my fork" && git push
platform/scripts/bootstrap.sh          # 15-25 minuti la prima volta (download immagini)
```

`bootstrap.sh` è idempotente: crea il cluster kind e avvia cloud-provider-kind (LoadBalancer + Gateway API). Poi installa con Helm metrics-server, kube-prometheus-stack, Kyverno e Argo CD, compila e carica l'immagine del frontend e genera i Secret Redis. Infine registra le Application Argo CD e aggiunge (con conferma) le voci in `/etc/hosts`. Da quel momento è **Git a guidare il cluster**.

> Le versioni dei chart Helm non sono fissate (si installa l'ultima stabile). Dopo il primo run riuscito, fissarle con `KPS_VERSION`, `KYVERNO_VERSION`, `ARGOCD_VERSION` e `METRICS_SERVER_VERSION` per la riproducibilità (`helm list -A` mostra quelle installate).

## 6. Verifica e test

```bash
platform/scripts/smoke-test.sh dev     # home, prodotto, carrello, checkout, health, versione, metriche
platform/scripts/smoke-test.sh prod
platform/scripts/rbac-check.sh         # matrice permessi per persona (impersonation)
```

| Cosa | Come |
|---|---|
| Negozio | http://dev.boutique.local, http://boutique.local |
| Argo CD | `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080 |
| Grafana | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` → dashboard "Online Boutique - Overview" |
| Prometheus | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → `/alerts` |

## 7. Operazioni frequenti

```bash
platform/scripts/release.sh dev 1.1.0            # build + commit del tag + sync Argo CD + rollout
SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0   # promozione della stessa immagine in prod
platform/scripts/rollback.sh prod                # git revert dell'ultimo cambio all'overlay
platform/scripts/rollback.sh dev --emergency     # kubectl rollout undo (senza Git)
platform/scripts/chaos.sh list                   # scenari di guasto
platform/scripts/create-secrets.sh --rotate      # rotazione password Redis
platform/scripts/teardown.sh                     # rimuove tutto
```

Dettagli e diagnosi in [runbook](docs/challenge/runbook.md).

## 8. Pipeline CI

`.github/workflows/platform-ci.yaml` si attiva su push e PR che toccano `platform/`, `src/frontend/` o `kustomize/`:

1. **validate**: shellcheck, yamllint, render di overlay e chart Krateo, `kubeconform -strict` con gli schemi dei CRD (Gateway API, Argo CD, Prometheus Operator, Kyverno), controllo che nessun Secret finisca in Git.
2. **frontend**: `gofmt`, `go vet` e `go test -race`.
3. **image**: build, scansione Trivy (blocca sulle CVE CRITICAL che hanno una correzione disponibile), push su `ghcr.io/<owner>/boutique-frontend` solo da `main`.

La CI **non fa deploy** e non ha credenziali del cluster: è Argo CD che legge da Git.

## 9. Limiti noti

- Ambienti simulati con namespace sullo stesso cluster: nessun isolamento a livello di nodo o di control plane.
- Redis usa `emptyDir`: il carrello si perde al riavvio del pod (come nell'upstream).
- I Secret sono generati da uno script e non sono riconciliati da GitOps: in produzione si userebbero External Secrets o Sealed Secrets ([security](docs/challenge/security.md)).
- Le metriche applicative coprono solo il frontend. Gli altri servizi espongono solo probe e log; il tracing OpenTelemetry è predisposto upstream ma non attivato.
- Le CPU request sono ridotte per far stare due ambienti su 4 vCPU (`kind-sizing`): in produzione sarebbe un errore di capacity planning ([architettura](docs/challenge/architecture.md#capacity)).

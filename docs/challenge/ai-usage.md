# Uso dell'AI nella challenge

Questo documento dice in modo trasparente **chi ha fatto cosa**, **cosa è stato verificato e come**, e **dove l'AI ha sbagliato**. Gli errori sono la parte più utile: mostrano perché ogni output è passato da una verifica prima di entrare nel repository.

## 1. Strumenti e modalità di lavoro

| Strumento | Dove | Per cosa |
|---|---|---|
| **Claude (Opus 5.5) in modalità agente** su claude.ai | Workspace Linux remoto con shell, git, Go, kustomize, kubeconform, shellcheck, ricerca web | Analisi del repository upstream, progettazione, scrittura di manifest, script, pipeline e documentazione, validazione statica |
| **Claude Code** nel terminale della VM Ubuntu | VM locale con Docker e kind | Esecuzione reale: bootstrap, demo, troubleshooting sul cluster vivo, correzioni |

**Divisione dei ruoli.** Io ho fornito il testo della challenge, i vincoli (VM con 4 vCPU e 10 GB, consegna in giornata, nessuna esigenza di velocità) e le decisioni di indirizzo. Ho rivisto gli output e li ho eseguiti e verificati sul cluster. L'agente ha fatto analisi, implementazione e prima validazione. **La responsabilità tecnica di ciò che è nel repository resta mia**: ogni file è stato letto e tutto ciò che si può eseguire è stato eseguito (vedi §6 per ciò che resta da verificare dal vivo).

**Vincolo scoperto all'inizio e gestito.** Il workspace dell'agente non raggiunge i registry di container (Docker Hub, GCR, registry.k8s.io), quindi non può avviare un cluster. Invece di "fingere" un test, il lavoro è stato diviso:
- **validazione statica nel workspace**: render Kustomize, `kubeconform -strict` con schemi CRD, shellcheck, yamllint, `go test` del codice nuovo, validazione JSON Schema;
- **validazione dinamica nella VM**: bootstrap, smoke test, scenari di guasto.

## 2. Per ambito

### 2.1 Analisi iniziale

| Problema | Approccio | Risultato | Verifica |
|---|---|---|---|
| Capire l'app in fretta (11 servizi, 5 linguaggi) | L'agente ha clonato l'upstream e letto **i manifest e il codice**, non solo il README: `kustomize/base`, `helm-chart/values.yaml`, `src/frontend/main.go`, `src/cartservice/Startup.cs`, `src/checkoutservice/main.go` | Mappa dei servizi, porte, dipendenze (dalle variabili `*_SERVICE_ADDR`), probe, securityContext | Tabelle in architecture.md ricavate dai file, non dalla memoria del modello |
| Trovare le lacune rispetto ai requisiti | Confronto requisito per requisito | Nessuna metrica Prometheus in nessun servizio (`initStats()` è un TODO); Redis senza autenticazione; Redis con SA `default`; tag mutabile `redis:alpine`; Service LoadBalancer pubblico; nessun seccomp | `grep -r prometheus src/` → vuoto; letti i manifest |
| Semantica degli errori nel checkout | Lettura di `PlaceOrder` | **Correzione di una prima affermazione errata**: l'agente aveva scritto che un guasto dell'email blocca l'ordine. Il codice mostra che gli errori di email e di `EmptyCart` sono solo loggati | `src/checkoutservice/main.go` righe 263–276 |

### 2.2 Implementazione

| Ambito | Dove l'AI ha accelerato | Dove è stato corretto o riscritto |
|---|---|---|
| Kustomize base/overlay | Struttura, patch di hardening, RBAC, HPA/PDB in pochi minuti | Patch JSON con indice sbagliato (§3.3); conflitto HPA/replicas (§3.4); repliche non dichiarate (§3.5) |
| Metriche frontend (Go) | Middleware + esposizione Prometheus + test | Scelta deliberata della stdlib invece di `client_golang`: nel workspace `go.sum` non era aggiornabile (proxy Go bloccato) e un `go.sum` non verificabile non entra nel repo. Trade-off documentato |
| Script operativi | Bootstrap idempotente, smoke test, release/rollback, chaos | Bug `grep -q` + `pipefail` (§3.6); shellcheck ha segnalato 3 warning, corretti |
| Pipeline CI | Struttura dei job | Pinning a SHA risolto con `git ls-remote`; uno SHA scritto a memoria era sbagliato (§3.2) |
| Policy Kyverno | Le 4 policy | La prima versione di `disallow-latest-tag` usava `foreach/deny` con wildcard in un operatore `Equals` (semantica non garantita): riscritta con il pattern documentato `"*:* & !*:latest"` |
| Krateo | Chart + schema + script PoC | Regola di naming della CRD generata verificata **nel sorgente** di core-provider invece che dedotta |

### 2.3 Operations e troubleshooting

Durante la scrittura, l'AI ha costruito gli strumenti di diagnosi: runbook per sintomo, alert collegati al runbook, scenari di guasto riproducibili.

Il caso di troubleshooting reale con l'AI sul cluster vivo è in **§4** (da compilare durante l'esecuzione nella VM).

### 2.4 Documentazione

Bozze generate dall'agente a partire dai file reali del repository. Ogni comando nei documenti corrisponde a un file o a uno script esistente. I dettagli che dipendono dal runtime (output, tempi) vanno confermati in VM (§6).

## 3. Errori dell'AI intercettati dalle verifiche

Esempi concreti, ognuno con *come* è emerso.

**3.1 Conoscenza obsoleta: ingress-nginx.** La prima scelta naturale per esporre il servizio in kind era ingress-nginx. Una ricerca fatta *prima* di scrivere i manifest ha mostrato che il progetto è stato **ritirato a marzo 2026** (niente più patch di sicurezza). Scelta corretta: **Gateway API**, implementata in locale da cloud-provider-kind. *Lezione*: su tutto ciò che riguarda lo "stato attuale" (versioni, progetti, best practice), il modello va verificato con fonti aggiornate.

**3.2 SHA di una GitHub Action scritto a memoria.** Tutte le action sono pinnate a SHA, una scelta motivata dall'incidente di marzo 2026 su `trivy-action` (CVE-2026-33634, tag riscritti). Per `actions/upload-artifact` l'agente aveva inizialmente scritto uno SHA e una versione (v4.6.2) "ricordati". Il controllo con `git ls-remote` ha mostrato che l'ultima versione è v7.0.2 con un altro SHA. *Lezione*: identificatori crittografici e versioni **non si generano, si risolvono**.

**3.3 Patch JSON con indice sbagliato.** Per impostare `USERS` del load generator l'agente aveva usato `op: replace` su `/env/2/value`. Ispezionando l'output renderizzato si è visto che l'indice 2 era **`RATE`**, non `USERS`: la patch cambiava silenziosamente la variabile sbagliata. Corretto con una strategic merge patch che seleziona la variabile per nome. *Lezione*: si verifica l'output renderizzato, non solo che il build "passi".

**3.4 HPA e replicas in conflitto.** La prima versione dell'overlay prod dichiarava `replicas: 2` sul frontend *e* un HPA. Con Argo CD in self-heal, i due controller avrebbero continuato a sovrascriversi. Rimosso `replicas`: ne è proprietario l'HPA.

**3.5 Deriva invisibile ad Argo CD.** Nello scenario `redis-down` (`scale --replicas=0`), il ripristino via sync non avrebbe funzionato: l'upstream **non dichiara `replicas`** e Argo CD può rilevare solo la deriva sui campi presenti in Git. Aggiunte le repliche esplicite nel base (escluso il frontend, vedi 3.4).

**3.6 Falso negativo nello smoke test.** `curl … | grep -q` con `set -o pipefail`: `grep -q` esce alla prima corrispondenza, curl riceve SIGPIPE e la pipeline fallisce **anche se il testo c'è**. Sostituito con `grep >/dev/null`.

**3.7 HPA con request ridotta.** Il componente `kind-sizing` porta le CPU request a 20m. Per l'HPA del frontend in prod significherebbe un utilizzo sempre altissimo e quindi lo scaling al massimo. La request del frontend in prod è stata reimpostata a 100m.

## 4. Caso di troubleshooting con l'AI

> Da compilare durante l'esecuzione nella VM con Claude Code. Scenario consigliato: `chaos.sh netpol-typo dev`. È il più istruttivo, perché tutti i pod restano `Ready` e solo il checkout fallisce.

| | |
|---|---|
| **Sintomo osservato** | _(es. ordine fallito, alert BoutiqueCheckoutFailing)_ |
| **Input dato all'AI** | _(output di `get pods`, log del frontend e di checkout, eventi; mai Secret)_ |
| **Prompt** | _vedi sotto_ |
| **Ipotesi proposte** | _(elenco, con ordine di probabilità)_ |
| **Comandi di verifica proposti** | _(quali eseguiti, quali scartati e perché)_ |
| **Causa identificata** | _ |
| **Correzione** | _(via Git o sync, non kubectl edit)_ |
| **Verifica** | _(smoke test, metrica tornata a 0, alert risolto)_ |
| **Valore** | _(tempo alla diagnosi; cosa avrei fatto senza AI)_ |

Prompt tipo, che limita l'AI alla diagnosi:

```text
Sei di supporto a un operatore L2. Contesto: Online Boutique su kind, namespace boutique-dev,
Argo CD con self-heal disattivato in dev. Sintomo: <...>. Allego output di: <comandi>.
1) Elenca al massimo 3 ipotesi ordinate per probabilità, con l'evidenza che le supporta.
2) Per ciascuna, il comando di sola lettura che la conferma o la esclude.
3) Non proporre modifiche finché una ipotesi non è confermata. Le correzioni devono passare da Git.
```

## 5. Governance personale dell'AI

| Regola | Come è stata applicata |
|---|---|
| **Niente segreti nei prompt** | La password Redis è generata *nel cluster* da `openssl rand` e non è mai stampata né incollata. Nei prompt di troubleshooting vanno log ed eventi, mai `get secret -o yaml` |
| **Comandi distruttivi solo se compresi** | Gli script usano sempre `--context kind-boutique` (nessun rischio di agire sul cluster sbagliato); teardown e chaos in prod chiedono conferma; in prod nessun `kubectl edit`, solo Git |
| **Validare prima di eseguire** | Manifest → `kustomize build` + `kubeconform -strict`; script → `shellcheck` + `bash -n`; Go → `go vet` + `go test -race`; schema Krateo → `jsonschema` con input validi e non validi |
| **Plausibile ≠ funzionante** | Ciò che non è stato eseguito è elencato in §6 e non presentato come testato |
| **Fonti per lo stato attuale** | Ritiro di ingress-nginx, incidente Trivy, API di Krateo: verificati su fonti web aggiornate o sul codice sorgente |
| **Identificatori risolti, non generati** | SHA delle action via `git ls-remote`; GVK di Krateo dal sorgente |
| **Diff piccoli e leggibili** | Upstream non modificato tranne 4 file del frontend; tutto il resto in `platform/` e `docs/challenge/` |

## 6. Verifiche ancora da fare sul cluster

Elenco onesto di ciò che la validazione statica non può garantire. Da spuntare durante il primo bootstrap in VM:

- [ ] `go build` completo del frontend (toolchain 1.27, non disponibile nel workspace dell'agente); il codice nuovo è testato in isolamento
- [ ] cloud-provider-kind: Gateway con indirizzo e routing per host; necessità di rimuovere il label `exclude-from-external-load-balancers` sul nodo singolo
- [ ] kindnet applica davvero le NetworkPolicy (default deny + `netpol-typo`)
- [ ] Redis con `--requirepass $(REDIS_PASSWORD)` e cartservice con connection string `password=` funzionano
- [ ] Policy Kyverno: sintassi `"*:* & !*:latest"`, `failureAction` per regola, nessun falso positivo sui workload
- [ ] PSA `restricted` accetta tutti i pod (incluso l'init container del load generator)
- [ ] values di kube-prometheus-stack, Kyverno e Argo CD con le versioni correnti dei chart
- [ ] Pannelli e alert della dashboard con dati reali
- [ ] `helm lint`/`helm template` del chart Krateo; PoC: permessi del CDC per creare Application in `argocd`
- [ ] Durata reale del bootstrap e consumo di memoria (stima: 6–7 GB)

## 7. Valore prodotto e limiti

**Valore**: in circa una giornata, una piattaforma completa e coerente: packaging per 2 ambienti, GitOps, osservabilità, sicurezza, CI, runbook, scenari di guasto e PoC Krateo. Senza AI avrebbe richiesto diversi giorni. Il guadagno maggiore è stato su: lettura veloce di un codebase poliglotta, scrittura di YAML e script ripetitivi, documentazione. L'AI ha anche portato spunti che altrimenti sarebbero potuti sfuggire (pinning degli SHA dopo l'incidente Trivy, ritiro di ingress-nginx), ma solo perché sono stati verificati.

**Limiti riscontrati**:
- conoscenza datata su versioni e stato dei progetti (§3.1, §3.2);
- errori "plausibili" che passano la validazione sintattica (§3.3, §3.6): solo l'ispezione dell'output o l'esecuzione li fa emergere;
- tendenza a fare affermazioni sul comportamento del codice senza leggerlo (§2.1, checkout). Mitigazione: chiedere sempre la riga di codice o il comando che conferma l'affermazione.

# Sicurezza

Obiettivo: una sicurezza **minima ma reale e verificabile**. Ogni controllo ha un comando che lo dimostra, e i limiti residui sono dichiarati.

## 1. Secret

| | Implementazione | Verifica |
|---|---|---|
| Nessun segreto in Git | La password Redis è generata da `create-secrets.sh` (`openssl rand`) direttamente nel cluster; lo script non la stampa mai | La CI fallisce se un manifest renderizzato contiene `kind: Secret` |
| Separazione per ambiente | Password diversa per `boutique-dev` e `boutique-prod` | `k -n boutique-dev get secret redis-auth -o jsonpath='{.metadata.uid}'` ≠ prod |
| Consumo | Redis legge `REDIS_PASSWORD` da `secretKeyRef` (`--requirepass`); cartservice legge l'intera connection string da `secretKeyRef` | `k -n boutique-dev describe deploy cartservice` mostra il riferimento, non il valore |
| Accesso umano | Nessuna Role del team include `secrets` | `rbac-check.sh` → "read secrets: no" |
| Rotazione | `create-secrets.sh --rotate` → nuovo valore + restart di Redis e cartservice | |

Prima di questa modifica Redis era **senza autenticazione** nell'upstream: qualunque pod con accesso di rete alla porta 6379 poteva leggere o scrivere i carrelli.

**Limiti residui e via di produzione**
- Il Secret non è riconciliato da GitOps: se il namespace viene ricreato, va rigenerato. In produzione: **External Secrets Operator** con Vault o il secret manager del cloud (il valore resta nel vault e Git contiene solo il riferimento), oppure **Sealed Secrets** (il valore cifrato sta in Git).
- I Secret in etcd sono solo codificati in base64: in produzione va attivato l'encryption at rest (KMS).
- La password compare negli argomenti del processo `redis-server` (visibile con `ps` *dentro* il container). Alternativa: un file `redis.conf` montato da Secret.
- Il traffico Redis non è cifrato (niente TLS). Accettabile all'interno del namespace, protetto da NetworkPolicy; in produzione si usa TLS oppure mTLS tramite service mesh.

## 2. Identità dei workload e RBAC

- **Un ServiceAccount per servizio** (upstream) **più uno nuovo per Redis**, che nell'upstream usava `default`.
- **`automountServiceAccountToken: false`** su tutti i pod: nessun servizio chiama l'API Kubernetes, quindi nessun pod riceve un token. Un container compromesso non può interrogare l'API server.
- **Nessuna Role o RoleBinding per i workload**: i ServiceAccount esistono solo per identità e audit.

```bash
platform/scripts/rbac-check.sh      # "frontend SA can list pods: no", "token mounted: false"
```

### RBAC per le persone

| Persona (gruppo OIDC) | dev | prod |
|---|---|---|
| `team-boutique` | `boutique-developer`: lettura, log, port-forward, restart, rollback e scale dei Deployment, delete pod. **No Secret, no exec** | `boutique-viewer`: sola lettura, log. **No Secret, no exec, nessuna modifica** |
| `team-boutique-oncall` | — | viewer + `boutique-oncall`: patch dei Deployment (restart/rollback), scale, delete pod |
| Argo CD | applica i manifest | applica i manifest (unico canale di modifica ordinario in prod) |

Si verifica con l'impersonation, senza creare utenti: `kubectl auth can-i patch deployments -n boutique-prod --as alice --as-group team-boutique` → `no`.

In prod il gruppo oncall può agire durante un incidente, ma il self-heal di Argo CD annulla qualunque modifica non riportata in Git. Il runbook lo rende esplicito (`rollback.sh --emergency` sospende l'auto-sync e ricorda di riallinearlo).

### Guardrail GitOps (AppProject)

- `boutique`: può deployare solo in `boutique-dev` e `boutique-prod`, e a livello cluster solo l'oggetto `Namespace`. Niente ClusterRole, CRD o webhook. Non può gestire `ResourceQuota` né `LimitRange` (sono del platform team).
- `platform`: solo `gateway-infra`, `monitoring` e `ClusterPolicy` Kyverno.
- `boutique-selfservice` (Krateo): solo namespace `boutique-*`.

## 3. Sicurezza dei pod

| Controllo | Dove |
|---|---|
| Non-root (UID 1000), `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true` | upstream (verificato su tutti i container, init container incluso) |
| `seccompProfile: RuntimeDefault` | patch di piattaforma `pod-hardening.yaml` (mancava nell'upstream) |
| **Pod Security Admission `restricted` in enforce** su entrambi i namespace | `overlays/*/namespace.yaml` |
| Tag immagine espliciti (no `:latest`): Kyverno **Enforce** | `disallow-latest-tag`; inoltre `redis:alpine` (tag mutabile) → `redis:8-alpine` |
| Label owner obbligatoria: Kyverno **Enforce** | `require-owner-label` |
| Request/limit e probe: Kyverno **Audit** | `kubectl get policyreport -A` (finding atteso: `loadgenerator` senza probe) |

Prova che PSA funziona:

```bash
kubectl -n boutique-dev run root-test --image=busybox:1.38.0 --restart=Never -- sleep 5
# Error from server (Forbidden): pods "root-test" is forbidden: violates PodSecurity "restricted:latest" ...
```

## 4. Rete

- **Default deny** (ingress ed egress) in ogni namespace, più una NetworkPolicy per servizio che ammette solo i chiamanti reali (componente upstream `network-policies`, prima non attivo). Esempio: `paymentservice` accetta solo da `checkoutservice` sulla porta 50051; `redis-cart` solo da `cartservice`.
- **Unico ingresso pubblico**: Gateway → `frontend:80`. Rimosso il Service `frontend-external` di tipo LoadBalancer.
- **Metriche non esposte**: porta 9090 su un Service separato, non referenziato da nessuna HTTPRoute (lo smoke test lo verifica).
- Il Gateway accetta HTTPRoute solo da namespace con label `platform.example.com/gateway-access=true`.
- **Limite**: l'egress delle policy upstream è aperto (`egress: [{}]`), per semplicità e per il DNS. In produzione si restringe a DNS più destinazioni note. kindnet applica le NetworkPolicy da kind v0.24; lo scenario `netpol-typo` serve anche a dimostrarlo.

## 5. Supply chain e CI

- **Action GitHub pinnate a SHA del commit**, non a tag. Motivo concreto: a marzo 2026 76 tag su 77 di `aquasecurity/trivy-action` sono stati riscritti per distribuire un credential stealer (CVE-2026-33634). Chi referenziava i tag ha eseguito codice malevolo. Gli SHA usati qui sono stati risolti con `git ls-remote` e non trascritti a memoria (vedi [ai-usage](ai-usage.md)). Trivy è fissato alla v0.69.3, indicata come sicura dall'advisory.
- **Permessi minimi del token CI**: `contents: read` di default; `packages: write` solo nel job che pubblica, e push solo da `main`.
- **La CI non ha credenziali del cluster**: è Argo CD che legge da Git (modello pull). Una pipeline compromessa non può toccare il cluster direttamente.
- **Scansione delle immagini**: Trivy blocca la pubblicazione con CVE CRITICAL correggibili; le HIGH sono riportate.
- **Immagine frontend** distroless (`gcr.io/distroless/static`): niente shell né package manager, quindi superficie minima. Effetto operativo: niente `kubectl exec ... sh`, e per il debug si usa `kubectl debug` con un container effimero.

**Limiti residui**: immagini upstream non scansionate né firmate da noi (vengono dal registry CI di Google); nessuna verifica di firma all'ammissione (prossimo passo: cosign + policy Kyverno `verifyImages`); nessuna SBOM pubblicata.

## 6. Rischi operativi considerati

| Rischio | Mitigazione |
|---|---|
| Script eseguito contro il cluster sbagliato | Gli script usano sempre `--context kind-boutique` (funzione `k`), mai il contesto corrente |
| Comandi distruttivi | `teardown.sh` e gli scenari di guasto in prod chiedono conferma |
| Kyverno non disponibile blocca i deploy | Webhook in `failurePolicy: Fail` per le policy Enforce (default Kyverno): scelta consapevole (fail-closed). Il runbook §2.9 mostra come riconoscerlo |
| Deriva non tracciata in prod | Self-heal di Argo CD; RBAC del team in sola lettura |
| Rollback che non torna allo stato atteso | Tag immutabili (policy Enforce) + rollback via `git revert` |

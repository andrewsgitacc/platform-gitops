# platform-gitops

**Author:** Andrew Kyle — [LinkedIn](https://www.linkedin.com/in/andrew-kyle-1007591/)

Configuration for every component of the platform lab, which runs on the Kubernetes
cluster built in [labs/k8s](https://github.com/andrewsgitacc/labs/tree/main/k8s).
The overall plan and build order are in
[labs/platform](https://github.com/andrewsgitacc/labs/tree/main/platform).

Git is the source of truth: **Argo CD** deploys everything in this repo from `main`,
using the pinned chart versions, values and manifests below. A merged pull request is a
deployment; changes made directly in the cluster are reverted. `scripts/install.sh` is
only used to bootstrap a fresh cluster.

## Layout

```
components/<name>/
  chart.yaml       Helm chart: repo, chart, pinned version, release, namespace
  values.yaml      Helm values
  manifests/       Extra resources applied after the chart (pools, issuers, gateway...)
apps/<name>/       Workloads that run on the platform (hello = Phase 2 test app)
argocd/            Argo CD project + ApplicationSets: one Application per component and app
bootstrap/         root.yaml - the "app of apps", applied once by hand
scripts/           Bootstrap helpers, run on the utility server (dns.lab.local)
.github/workflows/ CI: render every chart and schema-check everything on each PR, using
                   schemas generated from the pinned charts' own CRDs
```

## Components

| Component | Version | What it does |
|---|---|---|
| [MetalLB](components/metallb) | chart 0.16.1 | LoadBalancer IPs 172.16.79.100–.119 on the Fusion NAT network (L2 mode) |
| [cert-manager](components/cert-manager) | v1.21.2 | Internal lab CA (`lab-ca` ClusterIssuer) and automatic certificates |
| [Envoy Gateway](components/envoy-gateway) | v1.9.1 | Kubernetes Gateway API. One gateway, `lab-gateway`, on **172.16.79.100**, HTTPS for `*.apps.lab.local` |
| [external-dns](components/external-dns) | chart 1.23.0 | Creates `<name>.apps.lab.local` records on the lab BIND server for every HTTPRoute |
| [Sealed Secrets](components/sealed-secrets) | chart 2.22.0 (v0.41.2) | Decrypts SealedSecrets from Git into Secrets; `kubeseal` on the utility server encrypts them |
| [metrics-server](components/metrics-server) | chart 3.14.0 (v0.9.0) | `kubectl top nodes/pods` (CPU and memory use) |
| [Rook operator](components/rook-ceph) | v1.21.1 | Runs Ceph on Kubernetes; Ceph CRDs and CSI drivers |
| [Ceph CSI drivers](components/ceph-csi-drivers) | chart 1.1.0 | The rbd and cephfs drivers that create and mount Ceph volumes (separate chart since Rook v1.21) |
| [Ceph cluster](components/rook-ceph-cluster) | v1.21.1 (Ceph v20) | 3 OSDs on the workers' 100 GB disks. StorageClasses `ceph-block` (default), `ceph-filesystem` (shared), `ceph-bucket` (S3). Dashboard https://ceph.apps.lab.local, S3 https://s3.apps.lab.local |
| [kube-prometheus-stack](components/kube-prometheus-stack) | chart 92.17.1 | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics; Kubernetes dashboards and alerts. https://grafana.apps.lab.local (admin / admin, lab only), https://prometheus.apps.lab.local, https://alertmanager.apps.lab.local |
| [Loki](components/loki) | chart 20.2.1 | Log storage, monolithic, data in the Ceph S3 bucket `loki-data`; 7-day retention |
| [Alloy](components/alloy) | chart 1.15.0 | Collects every pod's logs on every node and sends them to Loki |
| [Argo CD](components/argocd) | chart 10.10.2 (v3.5.4) | GitOps: deploys this repo, including itself. UI at https://argocd.apps.lab.local (Keycloak login) |
| [trust-manager](components/trust-manager) | v0.26.0 | Copies the lab CA (plus the public CAs) into a ConfigMap `lab-ca-bundle` in every namespace, so pods can trust `https://*.apps.lab.local` |
| [CloudNativePG](components/cloudnative-pg) | chart 0.29.1 (operator 1.30.1) | PostgreSQL operator; databases are `Cluster` resources next to the app that uses them |
| [Keycloak](components/keycloak) | keycloakx chart 7.4.0 (Keycloak 26.8.1) | Single sign-on for Argo CD and Grafana. https://keycloak.apps.lab.local (admin console: admin / admin, lab only). Realm `platform` as code, applied by keycloak-config-cli |

How Argo CD deploys this repo:

```
bootstrap/root.yaml  (applied once)
  -> argocd/  project "platform" + 2 ApplicationSets
       components -> one Application per components/<name>/  (chart + values.yaml + manifests/)
       apps       -> one Application per apps/<name>/          (app-<name>, namespace <name>)
```

To add a component: create `components/<name>/` with `chart.yaml`, `values.yaml` and
`manifests/`, open a PR, merge. Argo CD picks it up within ~3 minutes.

How a request reaches an app:

```
https://hello.apps.lab.local
  -> DNS (external-dns record on dns.lab.local) -> 172.16.79.100
  -> MetalLB -> Envoy (lab-gateway, wildcard cert from lab-ca)
  -> HTTPRoute hello -> Service -> pods
```

To publish a new app, give it an HTTPRoute attached to `lab-gateway` (section `https`)
with a hostname under `apps.lab.local`. DNS and TLS are automatic.

## Secrets and keys

No plain-text secrets are stored in this repo. Secrets are committed **encrypted** as
SealedSecrets: only the Sealed Secrets controller in this cluster holds the private key that
decrypts them, so they're safe in a public repo.

- **external-dns TSIG key**: `components/external-dns/manifests/tsig-sealedsecret.yaml`,
  sealed by `scripts/seal-external-dns-secret.sh` from `/etc/named/externaldns.key` on the
  utility server.
- **Keycloak SSO secrets** (Phase 7): the OIDC client secrets for Argo CD and Grafana and
  the Keycloak `admin` user's password, sealed by `scripts/seal-keycloak-secrets.sh` into
  `components/keycloak/manifests/realm-secrets-sealedsecret.yaml`,
  `components/argocd/manifests/argocd-oidc-sealedsecret.yaml` and
  `components/kube-prometheus-stack/manifests/grafana-oidc-sealedsecret.yaml` (one set: re-run
  the script and all three change). Keycloak's database password is generated by
  CloudNativePG inside the cluster.
- **Lab-only plain passwords**: the Grafana `admin` and Keycloak master-realm `admin`
  logins are `admin` / `admin`, in plain text in the values (kept as ways in when SSO is
  broken). Never do this outside a lab.
- **Sealing key** (the controller's private key): exists only in the cluster
  (`kube-system`, label `sealedsecrets.bitnami.com/sealed-secrets-key`) and in a backup made by
  `scripts/backup-sealing-key.sh`, kept on the Mac in `~/lab-secrets/`, **never in Git**. Lose it
  and every SealedSecret has to be re-sealed; leak it and anyone can decrypt them.
- **Lab root CA private key**: generated inside the cluster by cert-manager and only exists
  as the Secret `cert-manager/lab-root-ca`. Only the public certificate is exported.

> **The Mac does not trust the lab CA** (by choice): Mac `curl` commands use `-k` and
> browsers show a warning. Trusting it is optional (runbook step 2). If you do, keep in
> mind that anyone holding the CA's private key could create certificates your Mac trusts
> for any website, which is why the key never leaves the cluster.

## Where commands run

There are two copies of this repo; don't mix them up:

| Machine | Repo path | Used for |
|---|---|---|
| Mac | `~/GitHub/platform-gitops` | editing, committing, pushing, pull requests |
| Utility server (`ssh admin@172.16.79.10`) | `~/platform-gitops` | running `scripts/` and `kubectl`/`argocd`/`kubeseal` against the cluster |

The utility server's copy is only ever updated with `git pull`; changes are made on the Mac.

## Phase 7 runbook: Keycloak single sign-on

Keycloak (https://keycloak.apps.lab.local) becomes the login for **Argo CD** and **Grafana**.
New components: **trust-manager** (shares the lab CA with pods, so Argo CD and Grafana can
call Keycloak over HTTPS), **CloudNativePG** (Keycloak's PostgreSQL) and **Keycloak**. The
realm `platform` (clients, the group `platform-admins`, the user `admin`) is in Git
(`components/keycloak/manifests/realm.yaml`) and applied by keycloak-config-cli after every
sync. The built-in `admin` logins of Argo CD and Grafana keep working as a way in.
Commands run on the **utility server** unless marked *Mac*.

### 1. Seal the SSO secrets (before merging)

*Mac:* push the branch first (`git push -u origin phase-7-keycloak`), but don't merge yet:
Keycloak's realm Job, Argo CD and Grafana need the sealed secrets from this step. The
script is on the branch, so check it out on the utility server for a moment:

```bash
cd ~/platform-gitops && git fetch && git checkout phase-7-keycloak
./scripts/seal-keycloak-secrets.sh      # asks for a password for the Keycloak user "admin"
git checkout main
```

*Mac:* add the three files to the branch and push:

```bash
cd ~/GitHub/platform-gitops && git checkout phase-7-keycloak
scp admin@172.16.79.10:keycloak-sealed/realm-secrets-sealedsecret.yaml components/keycloak/manifests/
scp admin@172.16.79.10:keycloak-sealed/argocd-oidc-sealedsecret.yaml components/argocd/manifests/
scp admin@172.16.79.10:keycloak-sealed/grafana-oidc-sealedsecret.yaml components/kube-prometheus-stack/manifests/
git add components/*/manifests/*-sealedsecret.yaml
git commit -m "Phase 7: sealed Keycloak SSO secrets" && git push
```

### 2. Merge the Phase 7 pull request

Argo CD creates `trust-manager`, `cloudnative-pg` and `keycloak`, and updates `argocd` and
`kube-prometheus-stack`. Allow ~5–10 minutes: the database first, then Keycloak (its first
start takes 1–2 minutes), then the `keycloak-config` Job.

```bash
watch kubectl -n argocd get applications              # all Synced + Healthy
kubectl get bundle lab-ca-bundle                      # Synced True
kubectl -n argocd get configmap lab-ca-bundle         # exists (in every namespace)
kubectl -n keycloak get cluster,pods,pvc              # keycloak-db "Cluster in healthy state", keycloak-0 1/1
kubectl -n keycloak logs job/keycloak-config | tail -5  # ends with the import finishing, no ERROR
```

### 3. Restart Argo CD's server and Grafana

They read the CA bundle once at start-up; if they started before `lab-ca-bundle` existed,
the Keycloak login fails with "certificate signed by unknown authority".

```bash
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n monitoring rollout restart deployment kube-prometheus-stack-grafana
```

### 4. Keycloak

```bash
curl -s https://keycloak.apps.lab.local/realms/platform/.well-known/openid-configuration | jq -r .issuer
# https://keycloak.apps.lab.local/realms/platform
```

*Mac:* **https://keycloak.apps.lab.local/admin**, log in **admin / admin** (master realm,
**lab only**; Keycloak warns it's a temporary admin). Switch to the realm **platform**:
clients `argocd` and `grafana`, group `platform-admins`, user `admin`.

### 5. Argo CD login

*Mac:* **https://argocd.apps.lab.local** → **LOG IN VIA KEYCLOAK** → `admin` and the
password you chose in step 1. You land in Argo CD with full access; **User Info** shows the group
`platform-admins`. The CLI still uses the built-in admin (`argocd login argocd.apps.lab.local --grpc-web`).

### 6. Grafana login

*Mac:* **https://grafana.apps.lab.local** → **Sign in with Keycloak** → you're in as
`admin` with the **Admin** role (Administration → Users and access → Users). Grafana matches
it to its existing local `admin` account by login name, so it's the same Grafana user
whichever way you sign in. Users outside
`platform-admins` get **Viewer**.

### 7. Metrics and memory

```bash
P=/api/v1/namespaces/monitoring/services
kubectl get --raw "$P/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health)"' | grep -E 'keycloak|cnpg|trust' | sort -u
# keycloak..., keycloak-db, cnpg..., trust-manager... all "up"
kubectl top nodes
kubectl top pods -n keycloak
```

### Phase 7 done when

- [ ] All Applications Synced + Healthy; `lab-ca-bundle` in every namespace
- [ ] `keycloak-db` healthy, `keycloak-0` Ready, `keycloak-config` Job completed
- [ ] Argo CD: Keycloak login as `admin` with admin rights
- [ ] Grafana: Keycloak login as `admin` with the Admin role
- [ ] Keycloak, its database, CloudNativePG and trust-manager scraped by Prometheus
- [ ] Workers still have memory headroom

## Phase 6 runbook: Observability

Metrics (Prometheus), alerts (Alertmanager), logs (Loki + Alloy) and dashboards (Grafana).
Ceph, Argo CD and cert-manager now expose metrics too. Commands run on the **utility
server** unless marked *Mac*.

### 1. Merge the Phase 6 pull request

Argo CD creates `kube-prometheus-stack`, `loki` and `alloy`, and updates `rook-ceph`,
`rook-ceph-cluster`, `argocd` and `cert-manager` (metrics on). Allow ~5–10 minutes: the
Prometheus CRDs come first, then the operator, then Prometheus/Grafana with their Ceph
volumes. Apps that need the monitoring CRDs retry until they exist.

```bash
watch kubectl -n argocd get applications            # all Synced + Healthy
kubectl -n monitoring get pods                      # prometheus-..., alertmanager-..., grafana, loki-0, alloy-xxxxx (one per node)
kubectl -n monitoring get pvc                       # Bound, ceph-block
kubectl -n monitoring get objectbucketclaim         # loki-bucket Bound
```

### 2. Prometheus is scraping everything

*Mac:* open **https://prometheus.apps.lab.local** → Status → Targets. Everything should be
**UP**, including `rook-ceph`, `argocd-*` and `cert-manager`. Or on the utility server,
through the Kubernetes API server's service proxy (the Prometheus, Alertmanager and Loki
images have no `wget` or `curl`, so `kubectl exec ... wget` doesn't work):

```bash
P=/api/v1/namespaces/monitoring/services
kubectl get --raw "$P/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | select(.health!="up") | "\(.labels.job) \(.lastError)"'
# no output = every target up
```

### 3. Alerts

*Mac:* **https://alertmanager.apps.lab.local**. Expect only **Watchdog** (an always-firing
"alerting works" heartbeat) and possibly **InfoInhibitor**. Anything else is worth a look.
From the utility server:

```bash
kubectl get --raw "$P/kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts" \
  | jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname' | sort | uniq -c
#   1 Watchdog
```

### 4. Grafana

*Mac:* **https://grafana.apps.lab.local**, log in **admin / admin** (lab only). Click
**Skip** on the change-password prompt: a password set there is stored on Grafana's volume
and overrides the chart's `adminPassword`. Login lockout after wrong passwords is turned
off (`disable_brute_force_login_protection`, **lab only**). Check:

- Dashboards → **Kubernetes / Compute Resources / Cluster** shows CPU and memory per namespace
- Dashboards → **Platform** → **Ceph Cluster - Advanced**, **OSD Overview**, **Ceph Pools
  Overview** show HEALTH_OK, 3 OSDs and the pools (Ceph's own dashboards for v20.2.4)
- Dashboards → **Platform** → **ArgoCD** shows the Applications

### 5. Logs

In Grafana: **Explore** → data source **Loki** → query `{namespace="argocd"}` → Argo CD's
logs (it logs constantly). Try `{namespace="rook-ceph", container="mgr"}`. The hello app
(podinfo) only logs when it starts or stops, so `{namespace="hello"}` is often empty for the
default last hour: widen the time range.

From the utility server:

```bash
kubectl get --raw "$P/loki:3100/proxy/loki/api/v1/labels" | jq -r '.data[]'
# app container instance job namespace node pod service_name
kubectl get --raw "$P/loki:3100/proxy/loki/api/v1/query_range?query=%7Bnamespace%3D%22argocd%22%7D&limit=3" \
  | jq -r '.data.result[].values[][1]'
# recent Argo CD log lines (add &since=72h for older logs)
```

Logs are stored in Ceph: `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- radosgw-admin bucket stats --bucket loki-data | jq '.usage'`
shows the bucket growing.

### 6. Memory check

```bash
kubectl top nodes
kubectl top pods -n monitoring --sort-by=memory
```

Measured after Phase 6: workers ~5.6 GB each (~59%), ~17 GB in total; Prometheus ~1.4 GB,
Grafana ~0.5 GB, Loki ~0.25 GB, Alloy 70–200 MB per node. Control planes 2.3–3 GB of their
4 GB (66–85%).

### Phase 6 done when

- [ ] All Applications Synced + Healthy; monitoring PVCs and the Loki bucket Bound
- [ ] Every Prometheus target UP (Ceph, Argo CD, cert-manager included)
- [ ] Only Watchdog (and InfoInhibitor) firing in Alertmanager
- [ ] Grafana: Kubernetes, Ceph and Argo CD dashboards show data
- [ ] Loki: `{namespace="argocd"}` returns logs in Grafana Explore
- [ ] Workers still have memory headroom

## Phase 5 runbook: Rook-Ceph storage

Ceph turns the empty 100 GB disk on each worker into replicated storage for the whole
platform. Commands run on the **utility server** unless marked *Mac*.

### 1. Prepare the workers (*Mac*, labs repo)

Loads the `rbd`/`ceph` kernel modules Ceph's drivers need and checks the disks are empty:

```bash
cd ~/GitHub/labs && git checkout main && git pull
cd k8s && ansible-playbook -i k8s_inventory.ini 08_prepare_ceph_nodes.yml -k -K
```

Each worker should report `/dev/nvme0n2:  100G` with no filesystem type.

### 2. Merge the Phase 5 pull request

Argo CD creates four Applications: `metrics-server`, `rook-ceph` (operator),
`ceph-csi-drivers` (the volume drivers) and `rook-ceph-cluster`. Ceph takes **5–10 minutes** to come up: monitors, then the manager,
then a disk-preparation job per worker, then the OSDs. `rook-ceph-cluster` shows
Progressing (and may retry) until the operator's CRDs exist — that's normal.

```bash
watch kubectl -n argocd get applications
watch kubectl -n rook-ceph get pods                 # Ctrl-C when the osd-0/1/2 pods are Running
```

### 3. Check Ceph

```bash
kubectl -n rook-ceph get cephcluster                # PHASE Ready, HEALTH HEALTH_OK
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree     # 3 OSDs up, one per worker
kubectl get storageclass                            # ceph-block (default), ceph-filesystem, ceph-bucket
kubectl get drivers.csi.ceph.io -n rook-ceph        # rook-ceph.rbd.csi.ceph.com, rook-ceph.cephfs.csi.ceph.com
kubectl -n rook-ceph get pods | grep -E 'ctrlplugin|nodeplugin'   # driver pods Running
kubectl top nodes                                   # worker memory use (metrics-server)
```

`HEALTH_WARN` for a few minutes after start-up is normal (pools being created).

### 4. Test block storage (data survives the pod)

```bash
kubectl create namespace storage-test
kubectl -n storage-test apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}      # no storageClassName: uses the default, ceph-block
YAML
kubectl -n storage-test run writer --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"data"}}],"containers":[{"name":"writer","image":"busybox","command":["sh","-c","echo hello-ceph > /d/test.txt"],"volumeMounts":[{"name":"d","mountPath":"/d"}]}]}}'
kubectl -n storage-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/writer --timeout=120s
kubectl -n storage-test delete pod writer
kubectl -n storage-test run reader --image=busybox --restart=Never -i --rm \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"data"}}],"containers":[{"name":"reader","image":"busybox","command":["cat","/d/test.txt"],"volumeMounts":[{"name":"d","mountPath":"/d"}]}]}}'
# prints: hello-ceph
kubectl get pv | grep storage-test                  # bound to ceph-block
```

### 5. Test S3 object storage

```bash
kubectl -n storage-test apply -f - <<'YAML'
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata: {name: test-bucket}
spec:
  generateBucketName: test
  storageClassName: ceph-bucket
YAML
sleep 15; kubectl -n storage-test get objectbucketclaim test-bucket     # PHASE Bound
kubectl -n storage-test run s3 --image=amazon/aws-cli --restart=Never -i --rm \
  --env AWS_ACCESS_KEY_ID="$(kubectl -n storage-test get secret test-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)" \
  --env AWS_SECRET_ACCESS_KEY="$(kubectl -n storage-test get secret test-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)" \
  --env BUCKET="$(kubectl -n storage-test get cm test-bucket -o jsonpath='{.data.BUCKET_NAME}')" \
  --command -- sh -c 'echo hello-s3 > /tmp/f && E=http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc && aws --endpoint-url $E s3 cp /tmp/f s3://$BUCKET/f && aws --endpoint-url $E s3 ls s3://$BUCKET/'
# lists: f
```

Clean up the tests: `kubectl delete namespace storage-test`

### 6. Ceph dashboard

Rook creates the dashboard user `admin` with a random password, stored in the Secret
`rook-ceph/rook-ceph-dashboard-password`. Set it to `admin` (**lab only**). Change it in both
places: Rook re-applies the Secret's value, so changing it only in Ceph would be reverted.

```bash
P=admin
kubectl -n rook-ceph patch secret rook-ceph-dashboard-password -p "{\"stringData\":{\"password\":\"$P\"}}"
printf '%s' "$P" | kubectl -n rook-ceph exec -i deploy/rook-ceph-tools -- \
  sh -c 'cat > /tmp/p && ceph dashboard ac-user-set-password admin -i /tmp/p --force-password; rm -f /tmp/p'
unset P
```

(`--force-password` skips the dashboard's password policy, which rejects `admin` as too short.
The password goes through a temporary file because Ceph doesn't take it on the command line.)

*Mac:* open **https://ceph.apps.lab.local** (click through the certificate warning), log in as
`admin` / `admin`. Also `curl -k -s -o /dev/null -w '%{http_code}\n' https://s3.apps.lab.local` → `200`.

### 7. Hand-off checks

```bash
kubectl top nodes          # workers well under 10 GB each (Ceph adds ~3-4 GB per worker)
kubectl -n argocd get applications                  # all Synced + Healthy
```

### Phase 5 done when

- [ ] `ceph status` shows HEALTH_OK with 3 OSDs up and in
- [ ] `ceph-block` is the default StorageClass; a PVC's data survives its pod
- [ ] An ObjectBucketClaim gets a bucket and the S3 test lists the object
- [ ] Ceph dashboard reachable at https://ceph.apps.lab.local
- [ ] `kubectl top nodes` works; workers have headroom
- [ ] All Applications Synced + Healthy

## Phase 4 runbook: Sealed Secrets

Two pull requests: the first adds the controller (Argo CD installs it), the second adds the
first sealed secret, which can only be made once the controller exists.
Commands run on the **utility server** unless marked *Mac*.

### 1. kubeseal on the utility server (*Mac*, labs repo)

```bash
cd ~/GitHub/labs && git checkout main && git pull
cd admin && ansible-playbook -i admin_inventory.ini install_admin_tools.yml -k -K
```

### 2. Install the controller (PR 1)

Merge the Phase 4 pull request in this repo (validate green). Within ~3 minutes Argo CD
creates the `sealed-secrets` Application:

```bash
watch kubectl -n argocd get applications                     # sealed-secrets Synced + Healthy
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets   # 1/1 Running
kubeseal --fetch-cert | head -2                               # -----BEGIN CERTIFICATE-----
```

### 3. Back up the sealing key — do this now

```bash
cd ~/platform-gitops && git checkout main && git pull
./scripts/backup-sealing-key.sh
```

*Mac:* keep the backup outside any Git repo:

```bash
mkdir -p ~/lab-secrets && chmod 700 ~/lab-secrets
scp admin@172.16.79.10:sealed-secrets-key.yaml ~/lab-secrets/
```

### 4. Seal the external-dns key (PR 2)

```bash
./scripts/seal-external-dns-secret.sh
```

*Mac:* copy the encrypted file into the repo, commit, open a PR, merge:

```bash
cd ~/GitHub/platform-gitops && git checkout main && git pull
git checkout -b external-dns-sealed-tsig
scp admin@172.16.79.10:tsig-sealedsecret.yaml components/external-dns/manifests/
git add components/external-dns/manifests/tsig-sealedsecret.yaml
git commit -m "external-dns: TSIG key as a SealedSecret" && git push -u origin external-dns-sealed-tsig
```

After the merge (~3 minutes):

```bash
kubectl -n external-dns get sealedsecret external-dns-rfc2136     # SYNCED True
kubectl -n external-dns get secret external-dns-rfc2136 -o jsonpath='{.metadata.ownerReferences[0].kind}'; echo   # SealedSecret
```

### 5. Test: the Secret comes back from Git

```bash
kubectl -n external-dns delete secret external-dns-rfc2136
sleep 10; kubectl -n external-dns get secret external-dns-rfc2136   # recreated by the controller
kubectl -n external-dns rollout restart deployment external-dns
kubectl -n external-dns logs deploy/external-dns --tail=20          # no TSIG / auth errors
dig +short hello.apps.lab.local                                     # still 172.16.79.100
```

*Mac:* `curl -k https://hello.apps.lab.local` still works.

### Phase 4 done when

- [ ] `sealed-secrets` Application Synced + Healthy, `kubeseal` works on the utility server
- [ ] Sealing key backed up to `~/lab-secrets/` on the Mac
- [ ] `tsig-sealedsecret.yaml` in Git; the Secret is owned by the SealedSecret
- [ ] Deleting the Secret recreates it; external-dns keeps working

## Phase 3 runbook: Argo CD

Argo CD reads **`main`**, so merge the Phase 3 pull request (validate check green) before
step 3. Commands run on the **utility server** unless marked *Mac*.

### 1. argocd CLI on the utility server (*Mac*, labs repo)

```bash
cd ~/GitHub/labs && git checkout phase-3-argocd && git pull   # or main once merged
cd admin && ansible-playbook -i admin_inventory.ini install_admin_tools.yml -k -K
```

### 2. Install Argo CD

```bash
ssh admin@172.16.79.10
cd ~/platform-gitops && git checkout main && git pull
./scripts/install.sh argocd
kubectl -n argocd get pods                      # all Running
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

*Mac:* `curl -k -s https://argocd.apps.lab.local | grep -o '<title>.*</title>'` returns
`<title>Argo CD</title>`. In the browser, **https://argocd.apps.lab.local** (click through
the certificate warning) and log in as `admin` with the password above.

CLI login (on the utility server, which trusts the lab CA):

```bash
argocd login argocd.apps.lab.local --grpc-web --username admin
argocd account update-password                  # set your own admin password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### 3. Hand the platform over to Argo CD

```bash
kubectl apply -f bootstrap/root.yaml
watch kubectl -n argocd get applications        # Ctrl-C when all Synced + Healthy
```

Expected Applications: `root`, `metallb`, `cert-manager`, `envoy-gateway`, `external-dns`,
`argocd`, `app-hello`. First syncs take a few minutes; Argo CD retries automatically.

```bash
argocd app list
```

### 4. Remove the Helm release records

Argo CD now owns the resources, so Helm's records of the Phase 2 installs are stale.
Delete only the records — **never `helm uninstall`**, which would delete the resources:

```bash
for r in metallb-system/metallb cert-manager/cert-manager envoy-gateway-system/eg external-dns/external-dns argocd/argocd; do
  kubectl -n "${r%/*}" delete secret -l owner=helm,name="${r#*/}"
done
helm list -A                                    # empty
```

### 5. GitOps tests

**Self-heal** — a manual change is reverted:

```bash
kubectl -n hello scale deployment podinfo --replicas=1
kubectl -n hello get deployment podinfo -w      # back to 2 within seconds; Ctrl-C
```

**Change through Git** — on the *Mac*:

```bash
cd ~/GitHub/platform-gitops && git checkout main && git pull
git checkout -b hello-3-replicas
sed -i '' 's/  replicas: 2/  replicas: 3/' apps/hello/hello.yaml
git commit -am "hello: 3 replicas" && git push -u origin hello-3-replicas
```

Open the PR, wait for **validate**, merge. Within ~3 minutes:

```bash
kubectl -n hello get deployment podinfo         # 3/3
argocd app get app-hello                        # Synced to the new commit
```

(Or click **Refresh** on `app-hello` in the UI to sync straight away.)

### Phase 3 done when

- [ ] `argocd` CLI on the utility server
- [ ] https://argocd.apps.lab.local works (UI from the Mac, CLI on the utility server)
- [ ] All Applications Synced + Healthy, including `argocd` itself
- [ ] `helm list -A` is empty
- [ ] Self-heal reverts a manual scale
- [ ] A merged PR changes the cluster (hello at 3 replicas)

## Phase 2 runbook (history)

How the Phase 2 components were first installed, before Argo CD. These commands still work
for single components, but `./scripts/install.sh` with no arguments now only bootstraps
(all CRDs, Sealed Secrets, Argo CD) and Argo CD installs the rest. To rebuild everything
on a new cluster, see "Rebuilding the platform from scratch" in
[labs/platform](https://github.com/andrewsgitacc/labs/tree/main/platform#rebuilding-the-platform-from-scratch).

All commands run on the **utility server** unless marked *Mac*.

### 0. Get the repo onto the utility server

```bash
ssh admin@172.16.79.10
git clone https://github.com/andrewsgitacc/platform-gitops.git ~/platform-gitops
cd ~/platform-gitops
```

(After later changes are merged: `cd ~/platform-gitops && git pull`.)

### 1. MetalLB

```bash
./scripts/install.sh metallb
```

Test that the Mac can reach a LoadBalancer IP on the Fusion network. This uses the last
pool address, .119, so the gateway can keep .100:

```bash
kubectl create deployment lb-test --image=nginx
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: lb-test
  annotations:
    metallb.io/loadBalancerIPs: 172.16.79.119
spec:
  type: LoadBalancer
  selector: {app: lb-test}
  ports: [{port: 80, targetPort: 80}]
YAML
kubectl get svc lb-test          # EXTERNAL-IP 172.16.79.119
```

*Mac:* `curl -s -m 5 http://172.16.79.119 | head -4` shows the nginx welcome page (plain HTTP, so no `-k` needed).
Then clean up: `kubectl delete deployment,svc lb-test`

> If the curl from the Mac times out, stop here and report it: it means Fusion's NAT
> network isn't passing MetalLB's ARP replies (the same problem the k8s lab hit with
> keepalived), and Phase 2 switches to the fallback design.

### 2. cert-manager and the lab CA

```bash
./scripts/install.sh cert-manager
./scripts/export-lab-ca.sh       # trusts the CA here, writes ~/lab-root-ca.crt
```

The utility server now trusts the lab CA, so `curl` there verifies certificates normally.

**The Mac does not trust the lab CA.** Mac `curl` commands use `-k` (skip certificate
verification), and browsers show a certificate warning you click through. This keeps the
Mac's trust store untouched.

<details>
<summary>Optional: trust the lab CA on the Mac instead</summary>

Removes the browser warnings and the need for `-k` (asks for your Mac password):

```bash
scp admin@172.16.79.10:lab-root-ca.crt ~/Downloads/
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/lab-root-ca.crt
```

Safari and Chrome use the macOS keychain; Firefox has its own store. To remove it:
`sudo security delete-certificate -c "Lab Root CA" /Library/Keychains/System.keychain`
</details>

### 3. Envoy Gateway

```bash
./scripts/install.sh envoy-gateway
kubectl -n envoy-gateway-system get gateway lab-gateway   # ADDRESS 172.16.79.100, PROGRAMMED True
```

### 4. external-dns

```bash
./scripts/create-external-dns-secret.sh   # (replaced in Phase 4 by a SealedSecret in Git)
./scripts/install.sh external-dns
```

### 5. End-to-end test: hello app

```bash
kubectl apply -f apps/hello/hello.yaml
kubectl -n external-dns logs deploy/external-dns -f    # wait for "Adding RR: hello.apps.lab.local" then Ctrl-C
dig +short hello.apps.lab.local                        # 172.16.79.100
curl https://hello.apps.lab.local                      # JSON from podinfo, valid TLS (no -k)
```

*Mac* (needs `/etc/resolver/lab.local` from Phase 1):

```bash
curl -k https://hello.apps.lab.local                   # podinfo JSON (-k: lab CA not trusted on the Mac)
```

In the browser, **https://hello.apps.lab.local** shows a certificate warning (expected);
click through to the podinfo page, "Hello from the platform lab".

Check that external-dns cleans up after itself:

```bash
kubectl -n hello delete httproute hello
sleep 90; dig +short hello.apps.lab.local              # (empty)
kubectl apply -f apps/hello/hello.yaml                 # put it back
```

### Phase 2 done when

- [ ] Mac reaches a MetalLB IP (172.16.79.119 test)
- [ ] `lab-root-ca` Ready and trusted on the utility server
- [ ] `lab-gateway` Programmed on 172.16.79.100
- [ ] `hello.apps.lab.local` record created and removed automatically by external-dns
- [ ] `curl -k https://hello.apps.lab.local` works from the Mac
- [ ] `validate` GitHub Actions check green

## Troubleshooting

| Symptom | Look at |
|---|---|
| Service stuck `<pending>` | `kubectl -n metallb-system logs -l app.kubernetes.io/component=controller` |
| Certificate not Ready | `kubectl describe certificate -A`, `kubectl get certificaterequests -A` |
| Gateway not Programmed | `kubectl -n envoy-gateway-system describe gateway lab-gateway` |
| No DNS record | `kubectl -n external-dns logs deploy/external-dns`; on the DNS server `sudo journalctl -u named -n 50` |
| Browser certificate warning | Expected: the lab CA isn't trusted on the Mac (optional in step 2) |
| Application OutOfSync / Degraded | `argocd app get <name>`, then `argocd app diff <name>`; UI shows per-resource status |
| Gateway / HTTPRoute (or other objects) OutOfSync but `argocd app diff` is empty | Fields defaulted by Kubernetes. Argo CD uses server-side diff (`controller.diff.server.side` in `components/argocd/values.yaml`); after changing it, `argocd app get <name> --hard-refresh` |
| CI **validate** fails in kubeconform: "additional properties '...' not allowed" on a custom resource | The schema used is older than the chart. CI generates schemas from the pinned charts' CRDs first; if the kind isn't from one of our charts it falls back to the community catalog. Check the field exists in the CRD version you pinned |
| Application sync status `Unknown` | Argo CD couldn't render it: `kubectl -n argocd get application <name> -o jsonpath='{.status.conditions[*].message}'`. "not a valid chart repository ... 404": wrong `repo` in `chart.yaml` (check the chart's README for the current URL). The CI **validate** check fails on the same PR — don't merge until it's green |
| Application not picking up a merge | `argocd app get <name> --hard-refresh`, or Refresh in the UI |
| ApplicationSet created nothing | `kubectl -n argocd describe applicationset components` (conditions) |
| `no route to host` to 172.16.79.100 (gateway) | The Envoy pods aren't running, so MetalLB stops announcing the IP. Check `kubectl -n envoy-gateway-system get pods`; if they're `Evicted`, the nodes are out of disk — see [Pods Evicted / DiskPressure](#pods-evicted--diskpressure) |
| Pods `Evicted`, nodes tainted `disk-pressure` | See [Pods Evicted / DiskPressure](#pods-evicted--diskpressure) |
| `argocd login` says "Invalid username or password" | See [Argo CD admin password](#argo-cd-admin-password) |
| SealedSecret not turning into a Secret | `kubectl -n <ns> describe sealedsecret <name>` and `kubectl -n kube-system logs deploy/sealed-secrets-controller`. "no key could decrypt secret": sealed for another cluster/key - restore the key backup or re-seal. "already exists and is not managed by SealedSecret": annotate the Secret `sealedsecrets.bitnami.com/managed=true` |
| Ceph OSD pods missing (no `rook-ceph-osd-N`) | `kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=50`. Usually the disk isn't empty (has a partition/filesystem) or isn't named `nvme0n2` on that node (`lsblk` on the worker) |
| PVC `Pending` "waiting for a volume to be created by the external provisioner rook-ceph.rbd.csi.ceph.com" | The CSI drivers aren't deployed: `kubectl get drivers.csi.ceph.io -A` is empty. Since Rook v1.21 they come from the separate `ceph-csi-drivers` chart (component `ceph-csi-drivers`) |
| PVC stuck `Pending`, or pod can't mount a Ceph volume | `kubectl describe pvc <name>`; `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status`. "modprobe rbd" errors: run `labs/k8s/08_prepare_ceph_nodes.yml` |
| `ceph status` HEALTH_WARN (Argo CD shows `rook-ceph-cluster` Degraded) | `ceph health detail` in the tools pod. Clock skew: check chronyd on the workers. `TOO_MANY_PGS`: too many placement groups for 3 OSDs - don't mark pools `bulk`; the autoscaler shrinks them over ~30 min. `AUTH_INSECURE_*` (CSI keys use the older aes cipher): expected on kernel < 7.0, muted in `cephClusterSpec.healthCheck` with the reason |
| Pods `OOMKilled` / `Pending` "Insufficient memory" after Ceph | Worker RAM is full: `kubectl top nodes`. Raise workers to 12 GB (labs/platform → MacBook requirements) |
| Grafana / Prometheus pod `Pending` | Its PVC isn't bound: `kubectl -n monitoring get pvc`, `kubectl -n monitoring describe pvc <name>`. Check Ceph and the CSI drivers (Phase 5) |
| Prometheus target DOWN | Prometheus → Status → Targets shows the error. TLS/403 on kubelet: chart default handles it. etcd/scheduler/controller-manager/kube-proxy are deliberately not scraped (kubeadm binds them to 127.0.0.1) |
| `kubectl exec ... wget`: "executable file not found in $PATH" | The Prometheus, Alertmanager and Loki images have no shell tools. Query them through the API server instead: `kubectl get --raw /api/v1/namespaces/monitoring/services/<service>:<port>/proxy/<path>` (see the Phase 6 runbook) |
| Loki query `{namespace="hello"}` returns nothing | The hello app (podinfo) only logs at start-up and shutdown. Widen the time range, or check a busy namespace such as `{namespace="argocd"}` |
| No logs in Grafana (Loki) | `kubectl -n monitoring logs ds/alloy --tail=20` (push errors?) and `kubectl -n monitoring logs loki-0 -c loki --tail=30` (S3 errors: check `kubectl -n monitoring get objectbucketclaim loki-bucket` and that the Secret `loki-bucket` exists) |
| Grafana Ceph dashboard mostly N/A / "No data" but Status shows | Dashboard written for older Ceph metric names. Use Ceph's own dashboards from the Ceph source at the running Ceph version (`url:` in the kube-prometheus-stack values), not old grafana.com uploads |
| Grafana Ceph/Argo CD dashboards empty | The dashboard's Prometheus job names may differ from the dashboard's queries; check the panel's query in Explore. Rook: `monitoring.enabled` in both rook-ceph components |
| Grafana login fails with admin / admin (browser or `curl -u admin:admin` gets "Invalid username or password") | The password was changed at the first-login prompt (it's kept on Grafana's volume, so the chart value no longer applies). See [Grafana admin password](#grafana-admin-password) |
| Argo CD or Grafana Keycloak login: "x509: certificate signed by unknown authority" | The pod can't verify the lab CA. Check `kubectl -n argocd get configmap lab-ca-bundle` (and `-n monitoring`); if it's there, the pod started before it: `kubectl -n argocd rollout restart deployment argocd-server` / `kubectl -n monitoring rollout restart deployment kube-prometheus-stack-grafana`. No ConfigMap: `kubectl describe bundle lab-ca-bundle`, `kubectl -n cert-manager logs deploy/trust-manager` |
| Keycloak page "Invalid parameter: redirect_uri" or "Invalid client credentials" | The realm wasn't applied, or the secrets don't match. `kubectl -n keycloak logs job/keycloak-config`; check the three sealed files came from the same run of `seal-keycloak-secrets.sh` |
| `keycloak-config` Job failed / Argo CD shows the `keycloak` sync failed in PostSync | `kubectl -n keycloak logs job/keycloak-config`. "secret keycloak-realm-secrets not found": the sealed file isn't committed. 401: the master admin password isn't `admin` (changed in the console?). Fix, then Argo CD → keycloak → Sync to re-run it |
| `keycloak-0` not Ready / restarting | `kubectl -n keycloak logs keycloak-0 --tail=50`. Database errors: `kubectl -n keycloak get cluster keycloak-db` and `kubectl -n keycloak logs keycloak-db-1`. First start takes 1–2 minutes (startup probe allows 5) |
| Argo CD Keycloak login works but no applications / "permission denied" | The `groups` claim is missing or the user isn't in `platform-admins`: Argo CD → User Info shows the groups. RBAC is `g, platform-admins, role:admin` in `components/argocd/values.yaml` |
| Grafana Keycloak user is only Viewer | Same: no `platform-admins` in the `groups` claim. Grafana re-evaluates the role at every login |
| `argocd: command not found` | Run the admin tools playbook (Phase 3 runbook step 1) and open a new SSH session |

### Pods Evicted / DiskPressure

When a node's disk passes ~85% full, the kubelet evicts pods and refuses new ones. Fix the
disk first (node problem, documented in
[labs/k8s → Troubleshooting](https://github.com/andrewsgitacc/labs/tree/main/k8s#troubleshooting)),
then clean up and check the platform:

```bash
kubectl describe nodes | grep -E '^Name:|DiskPressure'                 # all False
kubectl delete pods -A --field-selector=status.phase==Failed --wait=false   # clear evicted pods (can be thousands)
kubectl get pods -A | grep -vE 'Running|Completed'                     # nothing stuck
kubectl -n envoy-gateway-system get pods                               # envoy pods 2/2 Running
curl -s https://hello.apps.lab.local | head -3                         # gateway answering
```

### Grafana admin password

Reset it to `admin` (**lab only**) from the utility server. This writes straight to
Grafana's database, so you don't need the old password:

```bash
kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
  grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  admin reset-admin-password admin
curl -sk -u admin:admin 'https://grafana.apps.lab.local/api/search?type=dash-db' | jq -r '.[].title'
```

If the log says "too many consecutive incorrect login attempts" (`kubectl -n monitoring logs
deploy/kube-prometheus-stack-grafana -c grafana --since=15m | grep -i blocked`), Grafana has
locked the account for 5 minutes. The lab turns that lockout off in the kube-prometheus-stack
values (`grafana.ini` → `security.disable_brute_force_login_protection: true`, **lab only**).

### Argo CD admin password

Get the initial password again (only exists until you delete it after the first login):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Copy and paste it rather than typing it. If it's rejected or the secret is gone, set a new
password directly (stores a bcrypt hash in `argocd-secret`):

```bash
NEWPASS='choose-a-password'
HASH=$(argocd account bcrypt --password "$NEWPASS")
kubectl -n argocd patch secret argocd-secret -p \
  "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server
argocd login argocd.apps.lab.local --grpc-web --username admin --password "$NEWPASS"
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
```
| `curl` fails on the Mac with a certificate error | Add `-k`, or trust the CA on the Mac |

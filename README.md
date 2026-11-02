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
.github/workflows/ CI: render every chart and schema-check everything on each PR
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
| [Ceph cluster](components/rook-ceph-cluster) | v1.21.1 (Ceph v20) | 3 OSDs on the workers' 100 GB disks. StorageClasses `ceph-block` (default), `ceph-filesystem` (shared), `ceph-bucket` (S3). Dashboard https://ceph.apps.lab.local, S3 https://s3.apps.lab.local |
| [Argo CD](components/argocd) | chart 10.10.2 (v3.5.4) | GitOps: deploys this repo, including itself. UI at https://argocd.apps.lab.local |

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

Argo CD creates three Applications: `metrics-server`, `rook-ceph` (operator) and
`rook-ceph-cluster`. Ceph takes **5–10 minutes** to come up: monitors, then the manager,
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

```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d; echo
```

*Mac:* open **https://ceph.apps.lab.local** (click through the certificate warning), log in as
`admin`. Also `curl -k -s -o /dev/null -w '%{http_code}\n' https://s3.apps.lab.local` → `200`.

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

How the Phase 2 components were first installed, before Argo CD. To rebuild everything on
a new cluster, see "Rebuilding the platform from scratch" in
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
| Application sync status `Unknown` | Argo CD couldn't render it: `kubectl -n argocd get application <name> -o jsonpath='{.status.conditions[*].message}'`. "not a valid chart repository ... 404": wrong `repo` in `chart.yaml` (check the chart's README for the current URL). The CI **validate** check fails on the same PR — don't merge until it's green |
| Application not picking up a merge | `argocd app get <name> --hard-refresh`, or Refresh in the UI |
| ApplicationSet created nothing | `kubectl -n argocd describe applicationset components` (conditions) |
| `no route to host` to 172.16.79.100 (gateway) | The Envoy pods aren't running, so MetalLB stops announcing the IP. Check `kubectl -n envoy-gateway-system get pods`; if they're `Evicted`, the nodes are out of disk — see [Pods Evicted / DiskPressure](#pods-evicted--diskpressure) |
| Pods `Evicted`, nodes tainted `disk-pressure` | See [Pods Evicted / DiskPressure](#pods-evicted--diskpressure) |
| `argocd login` says "Invalid username or password" | See [Argo CD admin password](#argo-cd-admin-password) |
| SealedSecret not turning into a Secret | `kubectl -n <ns> describe sealedsecret <name>` and `kubectl -n kube-system logs deploy/sealed-secrets-controller`. "no key could decrypt secret": sealed for another cluster/key - restore the key backup or re-seal. "already exists and is not managed by SealedSecret": annotate the Secret `sealedsecrets.bitnami.com/managed=true` |
| Ceph OSD pods missing (no `rook-ceph-osd-N`) | `kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=50`. Usually the disk isn't empty (has a partition/filesystem) or isn't named `nvme0n2` on that node (`lsblk` on the worker) |
| PVC stuck `Pending`, or pod can't mount a Ceph volume | `kubectl describe pvc <name>`; `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status`. "modprobe rbd" errors: run `labs/k8s/08_prepare_ceph_nodes.yml` |
| `ceph status` HEALTH_WARN | `ceph health detail` in the tools pod. Clock skew: check chronyd on the workers. "too few PGs"/autoscale warnings settle on their own |
| Pods `OOMKilled` / `Pending` "Insufficient memory" after Ceph | Worker RAM is full: `kubectl top nodes`. Raise workers to 12 GB (labs/platform → MacBook requirements) |
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

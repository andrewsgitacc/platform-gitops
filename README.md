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

Nothing secret is stored in this repo.

- **external-dns TSIG key**: created as a Secret by `scripts/create-external-dns-secret.sh`,
  straight from `/etc/named/externaldns.key` on the utility server. Phase 4 replaces this
  with a SealedSecret.
- **Lab root CA private key**: generated inside the cluster by cert-manager and only exists
  as the Secret `cert-manager/lab-root-ca`. Only the public certificate is exported.

> **The Mac does not trust the lab CA** (by choice): Mac `curl` commands use `-k` and
> browsers show a warning. Trusting it is optional (runbook step 2). If you do, keep in
> mind that anyone holding the CA's private key could create certificates your Mac trusts
> for any website, which is why the key never leaves the cluster.

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

How the Phase 2 components were first installed, before Argo CD. On a rebuilt cluster,
`./scripts/install.sh` (all components) then `kubectl apply -f bootstrap/root.yaml`
gets back to the same state.

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
./scripts/create-external-dns-secret.sh
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
| Application not picking up a merge | `argocd app get <name> --hard-refresh`, or Refresh in the UI |
| ApplicationSet created nothing | `kubectl -n argocd describe applicationset components` (conditions) |
| `curl` fails on the Mac with a certificate error | Add `-k`, or trust the CA on the Mac |

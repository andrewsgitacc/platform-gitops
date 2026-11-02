`tsig-sealedsecret.yaml` is the external-dns TSIG key, encrypted with Sealed Secrets
(created by `scripts/seal-external-dns-secret.sh`). Only this cluster's Sealed Secrets
controller can decrypt it, so it's safe in the public repo.

Only *.yaml files here are applied by Argo CD.

No extra manifests for external-dns: everything comes from the Helm chart.
The TSIG Secret is created outside Git (scripts/create-external-dns-secret.sh) until Phase 4.

Every component has a manifests/ folder so the Argo CD ApplicationSet can treat them all
the same way. Only *.yaml files here are applied.

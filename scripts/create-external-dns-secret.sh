#!/usr/bin/env bash
# Create the Kubernetes Secret holding external-dns's TSIG key.
# Run on the utility server (dns.lab.local): it reads the key BIND uses,
# /etc/named/externaldns.key (created by labs/dns add_apps_zone.yml), so the
# secret never passes through Git or the Mac. Phase 4 replaces this with a SealedSecret.
set -euo pipefail

KEY_FILE=/etc/named/externaldns.key
SECRET=$(sudo awk -F'"' '/secret/ {print $2}' "$KEY_FILE")
[[ -n "$SECRET" ]] || { echo "No secret found in $KEY_FILE" >&2; exit 1; }

kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-dns create secret generic external-dns-rfc2136 \
  --from-literal=tsig-secret="$SECRET" --dry-run=client -o yaml | kubectl apply -f -
echo "Secret external-dns/external-dns-rfc2136 created/updated."

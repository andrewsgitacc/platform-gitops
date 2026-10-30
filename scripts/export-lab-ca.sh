#!/usr/bin/env bash
# Export the lab root CA's PUBLIC certificate so machines can trust the lab's HTTPS.
# Run on the utility server. Trusts it locally (for curl) and writes ~/lab-root-ca.crt
# for copying to the Mac. The CA private key never leaves the cluster.
set -euo pipefail

OUT="$HOME/lab-root-ca.crt"
kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUT"
openssl x509 -in "$OUT" -noout -subject -enddate

sudo cp "$OUT" /etc/pki/ca-trust/source/anchors/lab-root-ca.crt
sudo update-ca-trust
echo "Trusted on $(hostname). Certificate written to $OUT"
cat <<'MSG'

On the Mac:
  scp admin@172.16.79.10:lab-root-ca.crt ~/Downloads/
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/lab-root-ca.crt
MSG

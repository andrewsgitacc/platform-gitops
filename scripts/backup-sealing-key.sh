#!/usr/bin/env bash
# Back up the Sealed Secrets private key. Without it, a rebuilt cluster can't decrypt
# any SealedSecret in Git and every secret has to be sealed again.
#
# Run on the utility server. Writes ~/sealed-secrets-key.yaml (mode 600).
# Copy it OFF the lab (e.g. to the Mac, outside any Git repo) and never commit it:
# anyone holding it can decrypt every SealedSecret in the public repo.
#
# Restore on a new cluster: install.sh does it automatically if ~/sealed-secrets-key.yaml
# exists when sealed-secrets is installed (or: kubectl apply -f ~/sealed-secrets-key.yaml
# and restart the controller).
set -euo pipefail

OUT="$HOME/sealed-secrets-key.yaml"
umask 077
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$OUT"
COUNT=$(grep -c 'kind: Secret' "$OUT" || true)
[[ "$COUNT" -gt 0 ]] || { echo "No sealing keys found - is the controller installed?" >&2; exit 1; }
echo "Backed up $COUNT sealing key(s) to $OUT"
cat <<'MSG'

Copy it to the Mac, outside any Git repo:
  mkdir -p ~/lab-secrets && chmod 700 ~/lab-secrets
  scp admin@172.16.79.10:sealed-secrets-key.yaml ~/lab-secrets/
MSG

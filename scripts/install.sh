#!/usr/bin/env bash
# Install / upgrade platform components with Helm, then apply their extra manifests.
# Run on the utility server (dns.lab.local) from a clone of this repo.
#
#   ./scripts/install.sh                      # all Phase 2 components, in order
#   ./scripts/install.sh cert-manager         # just one (re-runnable: helm upgrade --install)
#
# Each component lives in components/<name>/:
#   chart.yaml   - chart repo, name, pinned version, release name, namespace
#   values.yaml  - Helm values
#   manifests/   - extra resources applied after the chart (pools, issuers, gateways...)
#
# From Phase 3, Argo CD installs the same components from the same files (see argocd/
# and bootstrap/). This script is then only needed to bootstrap a fresh cluster:
# run it once for everything, then apply bootstrap/root.yaml and Argo CD takes over.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORDER=(metallb cert-manager envoy-gateway external-dns argocd)

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

install_chart() {
  local dir="$1" release ns repo chart version ref
  release=$(yq '.release' "$dir/chart.yaml")
  ns=$(yq '.namespace' "$dir/chart.yaml")
  repo=$(yq '.repo' "$dir/chart.yaml")
  chart=$(yq '.chart' "$dir/chart.yaml")
  version=$(yq '.version' "$dir/chart.yaml")
  local args=()
  if [[ "$repo" == oci://* ]]; then
    ref="$repo/$chart"
  else
    ref="$chart"; args=(--repo "$repo")
  fi
  log "helm: $release ($chart $version) -> namespace $ns"
  helm upgrade --install "$release" "$ref" "${args[@]}" \
    --version "$version" --namespace "$ns" --create-namespace \
    --values "$dir/values.yaml" --wait --timeout 10m
}

apply_manifests() {
  local dir="$1/manifests"
  [[ -d "$dir" ]] || return 0
  compgen -G "$dir/*.yaml" >/dev/null || return 0   # nothing to apply
  log "kubectl apply: ${dir#"$ROOT"/}"
  # Admission webhooks can take a few seconds to start answering after a fresh install.
  for attempt in $(seq 1 12); do
    if kubectl apply -f "$dir"; then return 0; fi
    echo "  apply failed (attempt $attempt/12), retrying in 10s..."; sleep 10
  done
  echo "ERROR: could not apply $dir" >&2; return 1
}

post_checks() {
  case "$1" in
    cert-manager)
      kubectl -n cert-manager wait certificate/lab-root-ca --for=condition=Ready --timeout=120s ;;
    envoy-gateway)
      kubectl -n envoy-gateway-system wait certificate/apps-wildcard --for=condition=Ready --timeout=120s
      kubectl -n envoy-gateway-system wait gateway/lab-gateway --for=condition=Programmed --timeout=300s
      echo "Gateway address: $(kubectl -n envoy-gateway-system get gateway lab-gateway -o jsonpath='{.status.addresses[0].value}')" ;;
    external-dns)
      kubectl -n external-dns rollout status deployment/external-dns --timeout=120s ;;
    argocd)
      kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
      echo "Argo CD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo" ;;
  esac
}

pre_checks() {
  if [[ "$1" == external-dns ]] && ! kubectl -n external-dns get secret external-dns-rfc2136 >/dev/null 2>&1; then
    echo "ERROR: secret external-dns/external-dns-rfc2136 missing - run scripts/create-external-dns-secret.sh first" >&2
    exit 1
  fi
}

components=("$@")
[[ ${#components[@]} -gt 0 ]] || components=("${ORDER[@]}")

for c in "${components[@]}"; do
  dir="$ROOT/components/$c"
  [[ -f "$dir/chart.yaml" ]] || { echo "Unknown component: $c" >&2; exit 1; }
  pre_checks "$c"
  install_chart "$dir"
  apply_manifests "$dir"
  post_checks "$c"
done
log "done: ${components[*]}"

#!/usr/bin/env bash
# One-command bootstrap: stands up the ENTIRE self-healing platform on a local
# kind cluster. Requires only Docker, kind, and kubectl.
set -euo pipefail
CLUSTER="${CLUSTER:-selfheal}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "checking prerequisites"
for c in docker kind kubectl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is not installed."; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running."; exit 1; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  say "kind cluster '$CLUSTER' already exists - reusing it"
else
  say "creating kind cluster '$CLUSTER'"
  kind create cluster --name "$CLUSTER" --config "$ROOT/kind-config.yaml"
fi

say "installing ingress-nginx"
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s || true

say "building images (canary + healer)"
docker build -t canary:dev --build-arg VERSION=dev "$ROOT/canary"
docker build -t healer:dev "$ROOT/controller"
kind load docker-image canary:dev healer:dev --name "$CLUSTER"

say "deploying observability"
kubectl apply -k "$ROOT/k8s/observability"

say "deploying the canary app"
kubectl create namespace canary --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize "$ROOT/k8s/apps/canary" \
  | sed 's#ghcr.io/aadi071/canary:dev#canary:dev#' | kubectl apply -f -

say "deploying the self-healing controller"
kubectl kustomize "$ROOT/k8s/controller" \
  | sed 's#ghcr.io/aadi071/healer:dev#healer:dev#' | kubectl apply -f -

say "waiting for rollouts"
kubectl -n canary     rollout status deploy/canary-app --timeout=150s
kubectl -n canary     rollout status deploy/healer     --timeout=150s
kubectl -n monitoring rollout status deploy/grafana    --timeout=180s

echo ""
echo "Platform is UP. Break a green deploy and watch it heal:"
echo "  kubectl -n canary port-forward svc/canary-app 8080:80 &"
echo "  curl -XPOST http://localhost:8080/fault/on"
echo "  kubectl -n canary logs deploy/healer -f"
echo "Tear down: ./teardown.sh"

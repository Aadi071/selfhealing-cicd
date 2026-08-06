#!/usr/bin/env bash
set -euo pipefail
KUBECTL_VERSION=v1.31.0
KIND_VERSION=v0.24.0
echo "==> installing kubectl ${KUBECTL_VERSION}"
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
echo "==> installing kind ${KIND_VERSION}"
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind
kubectl version --client
kind version
echo "==> tools ready. Run ./quickstart.sh to bring up the platform."

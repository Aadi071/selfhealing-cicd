#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-selfheal}"
echo "==> deleting kind cluster '$CLUSTER'"
kind delete cluster --name "$CLUSTER"
echo "done."

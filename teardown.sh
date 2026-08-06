#!/usr/bin/env bash
# Delete the whole local demo cluster. Nothing persists outside kind.
set -euo pipefail
CLUSTER="${CLUSTER:-selfheal}"
echo "==> deleting kind cluster '$CLUSTER'"
kind delete cluster --name "$CLUSTER"
echo "done."

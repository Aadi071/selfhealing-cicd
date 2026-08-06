#!/usr/bin/env bash
cat <<'EOF'

  === Self-Healing CI/CD Platform - Codespace ready ===

  Bring up the whole platform (a few minutes first time):
      ./quickstart.sh

  Then watch a green deploy heal itself:
      kubectl -n canary port-forward svc/canary-app 8080:80 &
      curl -XPOST http://localhost:8080/fault/on
      kubectl -n canary logs deploy/healer -f

  Tear down:  ./teardown.sh
EOF

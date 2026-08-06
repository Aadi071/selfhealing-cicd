#!/usr/bin/env bash
cat <<'EOF'

  ┌────────────────────────────────────────────────────────────┐
  │  Self-Healing CI/CD Platform — Codespace ready.            │
  └────────────────────────────────────────────────────────────┘

  Stand up the whole platform (takes a few minutes the first time):

      ./quickstart.sh

  Then watch a green deploy heal itself:

      kubectl -n canary port-forward svc/canary-app 8080:80 &
      curl -XPOST http://localhost:8080/fault/on
      kubectl -n canary logs deploy/healer -f

  Grafana:  kubectl -n monitoring port-forward svc/grafana 3000:3000
            (VS Code will offer to open the forwarded port)

  Tear down: ./teardown.sh

EOF

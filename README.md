# Self-Healing CI/CD Platform

A CI/CD **platform** — not a pipeline for one app.
It deploys apps to Kubernetes, smoke-tests them, and **rolls back automatically when
production error rate breaches a threshold** — rollback triggered by a live signal
*after* the pipeline has already gone green. P1 (doc editor) and P3 (RAG assistant)
are onboarded as real tenants to prove it generalizes.

**Stack:** k3s (single-node, Hetzner) · GitHub Actions · GHCR · Traefik ingress ·
Prometheus + Grafana · a custom rollback controller.

---

## Run it yourself

### Zero install — in your browser

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/aadi071/selfhealing-cicd)

Click the badge → wait for the Codespace to build → in the terminal run
`./quickstart.sh`. The whole platform comes up in a free browser VM (Docker, kind,
and kubectl are preinstalled). No account beyond GitHub, nothing on your machine.

### On your PC — one command

You need only **Docker**, **[kind](https://kind.sigs.k8s.io/)**, and **kubectl**.
The script builds everything and stands up the whole platform (monitoring + the
canary + the self-healing controller) on a local cluster.

```bash
# macOS / Linux
./quickstart.sh
```
```powershell
# Windows
.\quickstart.ps1
```

Then watch a green deploy heal itself:

```bash
kubectl -n canary port-forward svc/canary-app 8080:80 &
curl -XPOST http://localhost:8080/fault/on      # break it
kubectl -n canary logs deploy/healer -f          # watch the auto-rollback
```

Tear it all down with `./teardown.sh` (or `.\teardown.ps1`). Nothing persists
outside the kind cluster.

---

## Repo layout

| Path | What lives here |
|------|-----------------|
| `canary/` | Deliberately breakable test app (`/health`, `/metrics`, fault switch). The rig the platform is built and proven against. |
| `k8s/base/` | The manifest **contract**: Deployment, Service, Ingress, probes, `maxUnavailable: 0`. The shape every app conforms to. |
| `k8s/observability/` | Standalone Prometheus + Grafana (resource-limited), dashboard, deploy annotations. |
| `.github/workflows/` | Reusable deploy pipeline: build → GHCR → apply → rollout status. |
| `controller/` | ★ Self-healing controller — watches Prometheus, rolls back on breach. |
| `scripts/` | MTTR stopwatch: bad-deploy → detection → rollback → healthy. |
| `docs/` | Architecture notes, decisions, the measured MTTR number. |

---

## Build order (see the tracker task list)

- **P0** — canary + manifest contract + local kind cluster & GitHub repo
- **P1** — deploy pipeline + scoped CI credentials
- **P2** — smoke tests + pipeline rollback
- **P3** — Prometheus + Grafana
- **P4** — ★ self-healing controller + MTTR measurement
- **P5** — move onto the Hetzner k3s box
- **P6** — onboard P1 and P3 as tenants
- **P7** — README + demo video

## The one number that matters

`scripts/` measures real MTTR. It goes in this README as a measured value — never a
`[X]` placeholder.

# controller — the self-healing rollback watchdog

This is the differentiator of the whole project.

The pipeline (P2) rolls back a deploy that **fails its smoke test** — a
deploy-time safety net. This controller is different in kind: it watches the
**live production error rate** and rolls back a deploy that already passed smoke,
went green, and *then* started failing under real traffic. The rollback trigger
is a production signal, not pipeline state.

That distinction is the interview story. Most CI/CD portfolio projects stop at
"pipeline rolls back on a failed test." Very few close the loop from production
telemetry back to an automatic rollback.

## How it decides

Every few seconds it asks Prometheus for the app's 5xx ratio (scoped by
namespace), and ignores the app when there's no real traffic. If the ratio stays
above the threshold for N **consecutive** checks (debounce, so one blip doesn't
trigger it), it runs `kubectl rollout undo`, waits for the replacement to become
healthy, then confirms recovery *from the same live signal* — and reports MTTR.

```
       deploy goes green ──► runtime degradation ──► error ratio breaches
                                                            │
                                   N consecutive breaches ──┘
                                                            ▼
                                              kubectl rollout undo
                                                            ▼
                                    wait for healthy signal ──► report MTTR
```

Key config (flags or env): `--threshold` (default 20%), `--window` (30s),
`--breaches` (3 consecutive), `--interval` (5s), `--cooldown` (60s after a
rollback), `--min-rps` (ignore idle).

## Run it in the dev loop (local, now)

With the canary + observability up and Prometheus port-forwarded on :9090:

```powershell
python controller\healer.py --prom-url http://localhost:9090 --threshold 0.2
```

Then prove it heals a green deploy that goes bad:

```powershell
# in another shell, with a port-forward to the canary on :8080 and some traffic:
Invoke-RestMethod -Method POST http://localhost:8080/fault/on
# watch the controller log: breaches climb, then "Rolling back", then "RECOVERED. MTTR = ..."
```

## Measure the number for your resume

`scripts\measure-mttr.ps1` runs the whole experiment repeatedly and averages the
MTTR — that measured value replaces any "under 30s" guess in the top-level
README. (Don't ship a placeholder; that's the mistake Project 3's README made.)

## In-cluster (prod, P5)

`k8s/controller/` runs the healer as a Deployment with a **namespace-scoped**
Role — it can undo a rollout but touch nothing else (least privilege, and a nice
security talking point). CI builds the image the same way it builds the canary.

## Design notes / honest limits

- One healer watches one namespace. For multi-tenant (P6) you run one per app
  namespace, or generalize to a cluster-scoped controller. Per-namespace keeps
  RBAC tight and blast radius small.
- `rollout undo` reverts to the previous ReplicaSet, so there must be a prior
  good revision. If a *first* deploy is bad, the pipeline smoke test (P2) is the
  net that catches it — the two layers are complementary by design.
- The controller reacts to symptoms (error rate), not root cause. That's correct
  for a safety mechanism: restore service first, diagnose after.

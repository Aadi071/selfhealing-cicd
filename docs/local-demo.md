# Local self-healing demo (kind)

Goal: watch a green deploy go bad in "production" and get automatically rolled
back, then read a **measured MTTR**. This exercises tasks #7 (observability) and
#8 (self-healing) live, end to end.

The controller here runs as a plain `python` process using your existing kubectl
context (kind-selfheal) — no in-cluster RBAC needed for the dev loop. The
`k8s/controller/` manifests are only for the prod box (P5).

## One-time: monitoring up

```powershell
kubectl apply -k k8s\observability
kubectl -n monitoring rollout status deploy/prometheus
kubectl -n monitoring rollout status deploy/grafana
```

Make sure the canary is deployed and healthy (from earlier):

```powershell
kubectl -n canary get pods        # canary-app pods Running
```

## Four terminals

Open four PowerShell windows, all `cd`'d to the project root.

**T1 — Prometheus port-forward** (leave running):
```powershell
kubectl -n monitoring port-forward svc/prometheus 9090:9090
```

**T2 — Canary port-forward** for load + fault control (leave running):
```powershell
kubectl -n canary port-forward svc/canary-app 8080:80
```

**T3 — the self-healing controller** (leave running). Slightly snappier settings
for a legible demo:
```powershell
python controller\healer.py --prom-url http://localhost:9090 `
  --threshold 0.2 --window 20s --breaches 3 --interval 5 --cooldown 15
```
You should see: `self-healer watching canary/canary-app ...`

**T4 — run the experiment.** Start with a single run to confirm the loop, then
average:
```powershell
.\scripts\measure-mttr.ps1 -Iterations 1
# once that prints an MTTR:
.\scripts\measure-mttr.ps1 -Iterations 3
```

## What you should see

- T4 clears any fault, drives load for ~8s, then injects `FAULT_MODE=true`.
- T3 (controller): error ratio climbs, `breach 1/3 -> 2/3 -> 3/3`,
  `BREACH SUSTAINED ... Rolling back`, then `RECOVERED. MTTR = NN.Ns`.
- T4: `MTTR = NN.Ns`, and after 3 runs an `avg / min / max` line.
- Optional eye candy: Grafana (`kubectl -n monitoring port-forward svc/grafana
  3000:3000`, browse localhost:3000 -> "Canary Health & Deploys") shows the error
  ratio spike and a blue deploy line, then recovery.

That averaged number is the resume figure. Paste it to me and it goes straight
into the top-level README (task #11) — measured, not guessed.

## If it doesn't heal

- **T4 times out at 180s:** is T3 (the controller) actually running and pointed at
  `http://localhost:9090`? Is T1 up?
- **Controller logs `rps=0.0` / never breaches:** the load job isn't reaching the
  app — confirm T2's port-forward is up and `Invoke-RestMethod http://localhost:8080/work`
  answers.
- **Iterations 2/3 time out but #1 worked:** the controller's cooldown is still
  active — the `--cooldown 15` above is tuned for this; lower it further if needed.
- **`python` not found:** use `py` instead, or `python3`.

## Tear down when done

```powershell
# just stop the port-forwards / controller (Ctrl-C in T1-T3).
# leave the cluster up — we reuse it until the VPS is ready.
```

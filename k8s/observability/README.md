# Observability — Prometheus + Grafana

Standalone, resource-bounded monitoring for the platform. **Deliberately not**
`kube-prometheus-stack` — that's built for big clusters and would eat the 4GB
prod box. This is two small Deployments with hard memory limits.

```
observability/
├── namespace.yaml               # monitoring namespace
├── prometheus-rbac.yaml         # SA + ClusterRole (read pods/endpoints for discovery)
├── prometheus-deploy.yaml       # Prometheus (7d retention, 512Mi cap)
├── grafana-deploy.yaml          # Grafana (auto-provisioned, 256Mi cap)
├── kustomization.yaml           # builds the ConfigMaps from files/ below
└── files/
    ├── prometheus.yml           # annotation-based pod discovery
    ├── grafana-datasource.yaml  # points Grafana at Prometheus on boot
    ├── grafana-dashboard-provider.yaml
    └── dashboards/canary.json   # the Canary Health dashboard
```

## How it hangs together

- **Discovery is automatic.** Prometheus scrapes any pod with
  `prometheus.io/scrape: "true"` — which the base contract already stamps on
  every app. So the canary (and later P1/P3) show up with zero per-app config.
- **Grafana is zero-click.** Datasource and dashboard are provisioned from
  ConfigMaps at boot; anonymous viewer is on so the dashboard opens without a
  login for demos.
- **Deploy markers are metric-driven.** The dashboard's "Deploys" annotation
  fires on `changes(app_build_info[1m])` — because the canary bakes `VERSION`
  into `app_build_info`, every new build draws a line on the graph. No external
  Grafana API calls needed; a spike visibly lines up with the deploy that caused
  it.

## Apply on kind

```powershell
kubectl apply -k k8s\observability
kubectl -n monitoring rollout status deploy/prometheus
kubectl -n monitoring rollout status deploy/grafana
```

Open the dashboard:

```powershell
kubectl -n monitoring port-forward svc/grafana 3000:3000
# browse http://localhost:3000  -> Dashboards -> "Canary Health & Deploys"
# (anonymous viewer; admin/admin if you want to edit)
```

Confirm Prometheus is scraping the canary:

```powershell
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# browse http://localhost:9090/targets -> the canary pods should be UP
```

## See it react

With the canary port-forward and some traffic running, flip the fault and watch
the dashboard: error ratio climbs, the "Fault mode" stat goes red.

```powershell
Invoke-RestMethod -Method POST http://localhost:8080/fault/on
# ...watch Grafana...
Invoke-RestMethod -Method POST http://localhost:8080/fault/off
```

This is the signal the **self-healing controller (P4)** will watch to trigger an
automatic rollback.

## Prod notes (P5)

- Swap Prometheus `emptyDir` for a small PVC so history survives restarts.
- Change the Grafana admin password; put Grafana behind the ingress + TLS.

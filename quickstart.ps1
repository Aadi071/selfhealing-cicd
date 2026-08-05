<#
.SYNOPSIS
  One-command bootstrap (Windows): stands up the ENTIRE self-healing platform on a
  local kind cluster - monitoring, the canary app, and the self-healing controller
  running in-cluster. Requires only Docker Desktop, kind, and kubectl.

.EXAMPLE
  git clone <repo>; cd selfhealing-cicd; .\quickstart.ps1

  Re-runnable: skips the cluster if it already exists.
#>
param([string]$ClusterName = "selfheal")
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
function Say($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

Say "checking prerequisites"
foreach ($c in @("docker", "kind", "kubectl")) {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "'$c' is not installed. See README." }
}
docker info *> $null; if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and retry." }

if ((kind get clusters 2>$null) -contains $ClusterName) {
  Say "kind cluster '$ClusterName' already exists - reusing it"
} else {
  Say "creating kind cluster '$ClusterName'"
  kind create cluster --name $ClusterName --config "$root\kind-config.yaml"
}

Say "installing ingress-nginx"
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s 2>$null

Say "building images (canary + healer)"
docker build -t canary:dev --build-arg VERSION=dev "$root\canary"
docker build -t healer:dev "$root\controller"
kind load docker-image canary:dev healer:dev --name $ClusterName

Say "deploying observability (Prometheus + Grafana)"
kubectl apply -k "$root\k8s\observability"

Say "deploying the canary app"
kubectl create namespace canary --dry-run=client -o yaml | kubectl apply -f -
(kubectl kustomize "$root\k8s\apps\canary") -replace 'ghcr\.io/aadi071/canary:dev', 'canary:dev' | kubectl apply -f -

Say "deploying the self-healing controller (in-cluster)"
(kubectl kustomize "$root\k8s\controller") -replace 'ghcr\.io/aadi071/healer:dev', 'healer:dev' | kubectl apply -f -

Say "waiting for everything to be ready"
kubectl -n canary     rollout status deploy/canary-app --timeout=150s
kubectl -n canary     rollout status deploy/healer     --timeout=150s
kubectl -n monitoring rollout status deploy/grafana    --timeout=180s

Write-Host @"

============================================================
  Self-healing platform is UP.
============================================================

Watch the controller:
  kubectl -n canary logs deploy/healer -f

Open Grafana (anonymous view):
  kubectl -n monitoring port-forward svc/grafana 3000:3000
  # browse http://localhost:3000 -> "Canary Health & Deploys"

See it heal a green deploy that goes bad:
  kubectl -n canary port-forward svc/canary-app 8080:80
  # in another shell:
  Invoke-RestMethod -Method POST http://localhost:8080/fault/on
  # ...the healer detects the error spike and rolls it back automatically.

Measure MTTR over 3 runs:
  .\scripts\measure-mttr.ps1 -Iterations 3

Tear it all down:
  .\teardown.ps1
"@ -ForegroundColor Green

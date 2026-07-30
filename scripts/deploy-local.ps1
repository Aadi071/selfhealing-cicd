<#
.SYNOPSIS
  Local dev-loop deploy to the kind cluster. This is what we use to develop and
  prove smoke-test rollback (P2) and self-healing (P4) BEFORE the public k3s box
  exists - GitHub runners can't reach a laptop-local kind cluster, so CI can't.

.EXAMPLE
  .\scripts\deploy-local.ps1                 # healthy deploy, version "dev"
  .\scripts\deploy-local.ps1 -Version v2     # deploy tagged v2
  .\scripts\deploy-local.ps1 -Version v2 -Fault   # born-broken build (tests smoke rollback)
#>
param(
  [string]$Version = "dev",
  [switch]$Fault,
  [string]$ClusterName = "selfheal"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$img  = "canary:$Version"

Write-Host "==> building $img" -ForegroundColor Cyan
docker build -t $img --build-arg VERSION=$Version "$root\canary"

Write-Host "==> loading image into kind/$ClusterName" -ForegroundColor Cyan
kind load docker-image $img --name $ClusterName

Write-Host "==> applying overlay (image overridden to local $img)" -ForegroundColor Cyan
kubectl create namespace canary --dry-run=client -o yaml | kubectl apply -f -

# Render the overlay and swap the GHCR image ref for the locally-loaded one.
$rendered = kubectl kustomize "$root\k8s\apps\canary"
$rendered = $rendered -replace 'ghcr\.io/GHCR_OWNER/canary:dev', $img
$rendered | kubectl apply -f -

if ($Fault) {
  # Born-broken deploy. The pod still passes liveness/readiness (health is not
  # app-correctness, by design), so the ROLLOUT succeeds - it's the SMOKE TEST
  # (P2) that catches this. That distinction is the whole point.
  Write-Host "   (setting FAULT_MODE=true - /work will 500; rollout still goes Ready)" -ForegroundColor Yellow
  kubectl -n canary set env deploy/canary-app FAULT_MODE=true | Out-Null
}

Write-Host "==> waiting for rollout" -ForegroundColor Cyan
kubectl -n canary rollout status deploy/canary-app --timeout=120s

Write-Host "`nDone. Try it (in a second terminal, after starting a port-forward):" -ForegroundColor Green
Write-Host "  kubectl -n canary port-forward svc/canary-app 8080:80"
Write-Host "  Invoke-RestMethod http://localhost:8080/work"
Write-Host "  Invoke-RestMethod -Method POST http://localhost:8080/fault/on   # break a green deploy"

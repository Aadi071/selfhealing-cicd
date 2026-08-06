param([string]$ClusterName = "selfheal")
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
function Say($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

Say "checking prerequisites"
foreach ($c in @("docker","kind","kubectl")) {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "'$c' is not installed." }
}
docker info *> $null; if ($LASTEXITCODE -ne 0) { throw "Docker is not running." }

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

Say "deploying observability"
kubectl apply -k "$root\k8s\observability"

Say "deploying the canary app"
kubectl create namespace canary --dry-run=client -o yaml | kubectl apply -f -
(kubectl kustomize "$root\k8s\apps\canary") -replace 'ghcr\.io/aadi071/canary:dev','canary:dev' | kubectl apply -f -

Say "deploying the self-healing controller"
(kubectl kustomize "$root\k8s\controller") -replace 'ghcr\.io/aadi071/healer:dev','healer:dev' | kubectl apply -f -

Say "waiting for rollouts"
kubectl -n canary     rollout status deploy/canary-app --timeout=150s
kubectl -n canary     rollout status deploy/healer     --timeout=150s
kubectl -n monitoring rollout status deploy/grafana    --timeout=180s

Write-Host "`nPlatform is UP. Break it and watch it heal:" -ForegroundColor Green
Write-Host "  kubectl -n canary port-forward svc/canary-app 8080:80"
Write-Host "  Invoke-RestMethod -Method POST http://localhost:8080/fault/on"
Write-Host "  kubectl -n canary logs deploy/healer -f"

param([string]$ClusterName = "selfheal")
Write-Host "==> deleting kind cluster '$ClusterName'" -ForegroundColor Cyan
kind delete cluster --name $ClusterName
Write-Host "done." -ForegroundColor Green

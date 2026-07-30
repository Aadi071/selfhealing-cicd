<#
.SYNOPSIS
  Post-deploy smoke test (Windows / local dev loop twin of smoke.sh).
  Hits the app's work route N times; fails if the 5xx rate exceeds the threshold.

.EXAMPLE
  # against a port-forward:
  kubectl -n canary port-forward svc/canary-app 8080:80
  .\scripts\smoke.ps1 -Target http://localhost:8080
#>
param(
  [string]$Target = "http://localhost:8080",
  [int]$Requests = 30,
  [double]$MaxErrorRate = 0.0,
  [string]$Route = "/work"
)

# Wait for the target to be reachable/ready.
$ready = $false
for ($i = 0; $i -lt 10; $i++) {
  try {
    Invoke-WebRequest "$Target/readyz" -TimeoutSec 2 -UseBasicParsing | Out-Null
    $ready = $true; break
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) { Write-Error "SMOKE: target $Target never became ready"; exit 2 }

$errors = 0
for ($i = 0; $i -lt $Requests; $i++) {
  try {
    # On Windows PowerShell 5.1 a 5xx throws (no -SkipHttpErrorCheck); the catch
    # counts it. A 2xx returns normally. Both behaviors give us what we need.
    Invoke-WebRequest "$Target$Route" -TimeoutSec 5 -UseBasicParsing | Out-Null
  } catch {
    $sc = 0
    if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
    if ($sc -ge 500 -or $sc -eq 0) { $errors++ }
  }
}

$rate = [math]::Round($errors / $Requests, 3)
Write-Host "SMOKE: $errors/$Requests requests failed (5xx) - rate=$rate, threshold=$MaxErrorRate"
if ($rate -le $MaxErrorRate) { Write-Host "SMOKE: PASS" -ForegroundColor Green; exit 0 }
else { Write-Error "SMOKE: FAIL - error rate above threshold"; exit 1 }

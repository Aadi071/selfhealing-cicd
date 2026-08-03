<#
.SYNOPSIS
  Measures real MTTR for a green-then-bad deploy: inject a production fault into a
  healthy deployment, then time how long until the self-healing controller rolls
  it back and the live error signal returns to healthy. Averages over N runs.

.DESCRIPTION
  Prereqs (all on the kind dev loop):
    1. Canary deployed and healthy         (.\scripts\deploy-local.ps1)
    2. Observability up                     (kubectl apply -k k8s\observability)
    3. Prometheus port-forwarded:           kubectl -n monitoring port-forward svc/prometheus 9090:9090
    4. Canary port-forwarded (for load):    kubectl -n canary  port-forward svc/canary-app 8080:80
    5. The controller running against it:
         python controller\healer.py --prom-url http://localhost:9090 --threshold 0.2

  This script injects the fault with `kubectl set env FAULT_MODE=true` (a new bad
  revision that passes probes), which is exactly the "went bad after going green"
  case the controller exists for. The controller's `rollout undo` reverts to the
  prior healthy revision.

.EXAMPLE
  .\scripts\measure-mttr.ps1 -Iterations 3
#>
param(
  [string]$PromUrl = "http://localhost:9090",
  # Load goes through the ingress (localhost:80 + Host header), NOT a pod
  # port-forward - a port-forward pins to one pod and dies when a rollout
  # replaces it, killing the load mid-experiment. The ingress survives rollouts.
  [string]$AppUrl  = "http://localhost:80",
  [string]$HostHeader = "canary.127.0.0.1.nip.io",
  [string]$Namespace = "canary",
  [string]$Deployment = "canary-app",
  [double]$Threshold = 0.2,
  [int]$Iterations = 3
)
$ErrorActionPreference = "Stop"

function Get-ErrRatio {
  $expr = "sum(rate(http_requests_total{namespace=`"$Namespace`",status=~`"5..`"}[30s])) / clamp_min(sum(rate(http_requests_total{namespace=`"$Namespace`"}[30s])),0.001)"
  $u = "$PromUrl/api/v1/query?query=" + [uri]::EscapeDataString($expr)
  try {
    $r = Invoke-RestMethod $u -TimeoutSec 5
    if ($r.data.result.Count -eq 0) { return 0.0 }
    return [double]$r.data.result[0].value[1]
  } catch { return 0.0 }
}

$results = @()
for ($n = 1; $n -le $Iterations; $n++) {
  Write-Host "`n=== iteration $n/$Iterations ===" -ForegroundColor Cyan

  # 1. Make sure we start healthy (clear any leftover fault env, wait for rollout).
  kubectl -n $Namespace set env deploy/$Deployment FAULT_MODE- 2>$null | Out-Null
  kubectl -n $Namespace rollout status deploy/$Deployment --timeout=120s | Out-Null

  # 2. Background load so rate() has signal. Hits the ingress (survives rollouts)
  #    with an explicit Host header so no DNS is needed.
  $load = Start-Job -ScriptBlock {
    param($u, $h)
    while ($true) {
      try { Invoke-WebRequest "$u/work" -Headers @{ Host = $h } -TimeoutSec 3 -UseBasicParsing | Out-Null } catch {}
    }
  } -ArgumentList $AppUrl, $HostHeader
  Start-Sleep -Seconds 8   # let the baseline rate build up

  # 3. Inject the fault and start the clock.
  Write-Host "injecting fault (FAULT_MODE=true) - deploy is now green-gone-bad" -ForegroundColor Yellow
  $t0 = Get-Date
  kubectl -n $Namespace set env deploy/$Deployment FAULT_MODE=true | Out-Null

  # 4. Wait until the signal has gone bad and then recovered below threshold.
  $sawBad = $false; $mttr = $null
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    $ratio = Get-ErrRatio
    if (-not $sawBad -and $ratio -gt $Threshold) { $sawBad = $true; Write-Host ("  breached: {0:P0}" -f $ratio) }
    if ($sawBad -and $ratio -le $Threshold) { $mttr = ((Get-Date) - $t0).TotalSeconds; break }
    Start-Sleep -Seconds 2
  }

  Stop-Job $load -ErrorAction SilentlyContinue | Out-Null
  Remove-Job $load -Force -ErrorAction SilentlyContinue | Out-Null

  if ($mttr) {
    Write-Host ("  MTTR = {0:N1}s" -f $mttr) -ForegroundColor Green
    $results += $mttr
  } else {
    Write-Host "  no recovery within 180s - is the controller running?" -ForegroundColor Red
  }
}

if ($results.Count -gt 0) {
  $avg = ($results | Measure-Object -Average).Average
  $min = ($results | Measure-Object -Minimum).Minimum
  $max = ($results | Measure-Object -Maximum).Maximum
  Write-Host ("`nMTTR over {0} runs: avg {1:N1}s (min {2:N1}s, max {3:N1}s)" -f $results.Count,$avg,$min,$max) -ForegroundColor Green
  Write-Host "This is the number that goes in the README - measured, not guessed."
}

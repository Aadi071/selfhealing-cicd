#!/usr/bin/env bash
# Post-deploy smoke test. Hits the app's real work route N times and fails if the
# 5xx rate exceeds the threshold. This is what catches a deploy that went "Ready"
# but is actually serving errors (FAULT_MODE) — the rollout status check can't,
# because a faulted pod still passes its liveness/readiness probes by design.
#
# Env:
#   TARGET          base URL to hit           (default http://localhost:8080)
#   REQUESTS        number of probes          (default 30)
#   MAX_ERROR_RATE  allowed 5xx fraction 0..1 (default 0 — zero tolerance)
#   ROUTE           path to probe             (default /work)
#
# Exit 0 = healthy (within threshold), 1 = failed smoke, 2 = target unreachable.
set -euo pipefail

TARGET="${TARGET:-http://localhost:8080}"
REQUESTS="${REQUESTS:-30}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0}"
ROUTE="${ROUTE:-/work}"

# Wait briefly for the target to answer at all (readiness may lag the port-forward).
ready=0
for _ in $(seq 1 10); do
  if curl -fsS -o /dev/null --max-time 2 "${TARGET}/readyz" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "SMOKE: target ${TARGET} never became reachable/ready" >&2
  exit 2
fi

errors=0
for _ in $(seq 1 "$REQUESTS"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${TARGET}${ROUTE}" || echo 000)
  if [ "$code" -ge 500 ] || [ "$code" = "000" ]; then
    errors=$((errors + 1))
  fi
done

rate=$(awk "BEGIN{printf \"%.3f\", ${errors}/${REQUESTS}}")
echo "SMOKE: ${errors}/${REQUESTS} requests failed (5xx) — rate=${rate}, threshold=${MAX_ERROR_RATE}"

# Pass iff rate <= threshold.
if awk "BEGIN{exit !(${rate} <= ${MAX_ERROR_RATE})}"; then
  echo "SMOKE: PASS"
  exit 0
else
  echo "SMOKE: FAIL — error rate above threshold" >&2
  exit 1
fi

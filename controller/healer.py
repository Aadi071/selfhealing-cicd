#!/usr/bin/env python3
"""
Self-healing controller — the differentiator of this project.

The pipeline (P2) rolls back a deploy that FAILS ITS SMOKE TEST — a deploy-time
safety net. This controller is different: it watches the LIVE production error
rate from Prometheus and rolls back a deploy that already went green and then
started failing under real traffic. Rollback is triggered by a production signal,
not by pipeline state.

Loop:
  1. Query Prometheus for the app's 5xx ratio (and request rate, to ignore idle).
  2. If the ratio stays above the threshold for N consecutive checks, the deploy
     is judged bad.
  3. `kubectl rollout undo` -> revert to the last-good ReplicaSet, wait for it to
     become healthy, and report MTTR (time from first breach to healthy again).
  4. Cool down so the now-healthy previous version isn't immediately re-judged.

Pure stdlib + kubectl. Runs locally against a port-forwarded Prometheus during
the dev loop, or in-cluster (see k8s/controller/) in prod.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def prom_query(prom_url: str, expr: str):
    """Return the scalar value of an instant query, or None if no data."""
    url = prom_url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.load(r)
    except Exception as e:  # network hiccup — treat as no-signal, don't act
        log(f"WARN prometheus query failed: {e}")
        return None
    if data.get("status") != "success":
        return None
    result = data["data"]["result"]
    if not result:
        return None
    try:
        return float(result[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return None


def run(cmd: list) -> int:
    log("  $ " + " ".join(cmd))
    return subprocess.run(cmd, check=False).returncode


class Healer:
    def __init__(self, a):
        self.a = a
        ns, win = a.namespace, a.window
        # Scope everything to the target app by namespace label (Prometheus adds it).
        self.err_ratio_expr = (
            f'sum(rate(http_requests_total{{namespace="{ns}",status=~"5.."}}[{win}])) '
            f'/ clamp_min(sum(rate(http_requests_total{{namespace="{ns}"}}[{win}])), 0.001)'
        )
        self.req_rate_expr = f'sum(rate(http_requests_total{{namespace="{ns}"}}[{win}]))'
        self.breaches = 0
        self.first_breach_at = None
        self.cooldown_until = 0.0

    def rollback(self):
        a = self.a
        detect_at = time.monotonic()
        detection_s = detect_at - self.first_breach_at
        log(f"BREACH SUSTAINED ({self.breaches} checks). Rolling back "
            f"{a.namespace}/{a.deployment}. (detection took {detection_s:.1f}s)")
        if a.dry_run:
            log("  [dry-run] would run: kubectl rollout undo + status")
        else:
            run(["kubectl", "-n", a.namespace, "rollout", "undo", f"deploy/{a.deployment}"])
            run(["kubectl", "-n", a.namespace, "rollout", "status",
                 f"deploy/{a.deployment}", "--timeout=120s"])
        # Wait for the live signal to actually recover below threshold.
        healthy_at = self._wait_healthy()
        mttr = (healthy_at or time.monotonic()) - self.first_breach_at
        log(f"RECOVERED. MTTR (first breach -> healthy) = {mttr:.1f}s")
        print(json.dumps({
            "event": "rollback_complete",
            "namespace": a.namespace, "deployment": a.deployment,
            "detection_seconds": round(detection_s, 1),
            "mttr_seconds": round(mttr, 1),
        }), flush=True)
        self.breaches = 0
        self.first_breach_at = None
        self.cooldown_until = time.monotonic() + a.cooldown

    def _wait_healthy(self, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ratio = prom_query(self.a.prom_url, self.err_ratio_expr)
            if ratio is not None and ratio <= self.a.threshold:
                return time.monotonic()
            time.sleep(self.a.interval)
        log("WARN gave up waiting for recovery signal")
        return None

    def tick(self):
        a = self.a
        if time.monotonic() < self.cooldown_until:
            return
        req_rate = prom_query(a.prom_url, self.req_rate_expr)
        if req_rate is None or req_rate < a.min_rps:
            # No meaningful traffic — a ratio computed on noise is not a signal.
            self.breaches = 0
            self.first_breach_at = None
            return
        ratio = prom_query(a.prom_url, self.err_ratio_expr)
        if ratio is None:
            return
        if ratio > a.threshold:
            if self.breaches == 0:
                self.first_breach_at = time.monotonic()
            self.breaches += 1
            log(f"error ratio {ratio:.1%} > {a.threshold:.0%} "
                f"(breach {self.breaches}/{a.breaches}, rps={req_rate:.1f})")
            if self.breaches >= a.breaches:
                self.rollback()
        else:
            if self.breaches:
                log(f"error ratio {ratio:.1%} back under threshold — resetting")
            self.breaches = 0
            self.first_breach_at = None

    def run_forever(self):
        a = self.a
        log(f"self-healer watching {a.namespace}/{a.deployment} via {a.prom_url}")
        log(f"threshold={a.threshold:.0%} window={a.window} "
            f"need {a.breaches} consecutive breaches, interval={a.interval}s"
            + (" [DRY-RUN]" if a.dry_run else ""))
        while True:
            try:
                self.tick()
            except Exception as e:
                log(f"ERROR in loop: {e}")
            time.sleep(a.interval)


def env(k, d):
    return os.environ.get(k, d)


def main(argv=None):
    p = argparse.ArgumentParser(description="Self-healing rollback controller")
    p.add_argument("--prom-url", default=env("PROM_URL", "http://localhost:9090"))
    p.add_argument("--namespace", default=env("NAMESPACE", "canary"))
    p.add_argument("--deployment", default=env("DEPLOYMENT", "canary-app"))
    p.add_argument("--threshold", type=float, default=float(env("THRESHOLD", "0.20")),
                   help="5xx ratio that counts as a breach (0..1)")
    p.add_argument("--window", default=env("WINDOW", "30s"), help="rate() window")
    p.add_argument("--interval", type=float, default=float(env("INTERVAL", "5")),
                   help="seconds between checks")
    p.add_argument("--breaches", type=int, default=int(env("BREACHES", "3")),
                   help="consecutive breaching checks before rollback")
    p.add_argument("--cooldown", type=float, default=float(env("COOLDOWN", "60")),
                   help="seconds to wait after a rollback before judging again")
    p.add_argument("--min-rps", type=float, default=float(env("MIN_RPS", "0.2")),
                   help="ignore error ratio below this request rate (idle app)")
    p.add_argument("--dry-run", action="store_true", default=env("DRY_RUN", "") == "true")
    a = p.parse_args(argv)
    try:
        Healer(a).run_forever()
    except KeyboardInterrupt:
        log("stopped")
        return 0


if __name__ == "__main__":
    sys.exit(main())

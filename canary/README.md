# canary

A deliberately breakable service. It is the test rig the whole platform is built
and proven against — not a shippable app.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/healthz` | Liveness. Always 200 (a faulted pod stays alive so the platform can detect + roll it back). |
| GET | `/readyz` | Readiness. 503 until `READY_DELAY_SECONDS` elapses, then 200. Gates rollout traffic. |
| GET | `/metrics` | Prometheus exposition (`http_requests_total`, `app_fault_mode`, `app_build_info`). |
| GET | `/work`, `/` | The "real work" route smoke tests hit and Prometheus watches. 200 normally, error when faulted. |
| POST | `/fault/on?ratio=0.5` | **Runtime** fault: makes a green deploy start erroring on command. |
| POST | `/fault/off` | Clear the runtime fault. |

## Config (env)

| Var | Default | Meaning |
|-----|---------|---------|
| `PORT` | `8080` | Listen port. |
| `VERSION` | `dev` | Shown in responses + `app_build_info`. Set per build to watch v1→v2→rollback. |
| `FAULT_MODE` | `false` | **Deploy-time** fault: start erroring immediately (proves pipeline rollback). |
| `FAULT_RATIO` | `1.0` | Fraction of `/work` requests that fail when faulted (0..1). |
| `FAULT_STATUS` | `500` | Status code returned when faulted. |
| `READY_DELAY_SECONDS` | `0` | Delay before readiness turns true. |

## Two ways to break it — and why there are two

- **`FAULT_MODE=true`** → bad from startup. Smoke tests fail, the **pipeline** rolls back. (P2)
- **`POST /fault/on`** → deploy passes, goes green, *then* degrades. Prometheus error
  rate climbs and the **self-healing controller** rolls back on the live signal. (P4)

That second case — failure *after* green — is the whole point of the project.

## Run locally

```sh
go run .                       # healthy on :8080
FAULT_MODE=true go run .        # born broken
curl -XPOST localhost:8080/fault/on   # break a running one
```

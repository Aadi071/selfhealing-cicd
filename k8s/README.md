# k8s — the manifest contract

`base/` is the shape **every** app on the platform conforms to. Apps live in
`apps/<name>/` as thin kustomize overlays that patch only what differs
(image, name, host, env). Onboarding P1 and P3 later (P6) is just two more
overlays — that repeatability is the platform's whole value proposition.

```
k8s/
├── base/                 # the contract (Deployment, Service, Ingress)
│   ├── deployment.yaml   #   rollout + probes + securityContext live here
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
└── apps/
    └── canary/           # first tenant — the overlay pattern others copy
        ├── namespace.yaml
        ├── patch-deployment.yaml
        ├── patch-ingress.yaml
        └── kustomization.yaml
```

## What the contract guarantees (and why)

- **`maxUnavailable: 0`** — a rolling update never drops below full capacity. A
  broken new pod that never goes Ready simply never receives traffic; the old
  pods keep serving. This is half of "self-healing" — the deploy can't hurt you
  if it can't take traffic.
- **Liveness ≠ readiness.** Liveness (`/healthz`) only asks "is the process
  alive?" and stays green even when the app is faulted — so a bad deploy is
  *detected and rolled back*, not silently restarted into hiding. Readiness
  (`/readyz`) asks "should I get traffic now?" and gates the rollout.
- **Locked-down securityContext** — nonroot, read-only root FS, all caps
  dropped, seccomp RuntimeDefault. Cheap to add, and a real talking point.
- **30s termination grace** — reserves the drain window the WebSocket tenant
  (P1) needs; foreshadowed here so the contract doesn't change later.
- **Prometheus scrape annotations** — standalone Prometheus (P3) discovers pods
  by annotation, no operator required.

## Verify it renders (do this once kustomize/kubectl is installed)

```sh
# from repo root
kubectl kustomize k8s/apps/canary        # or: kustomize build k8s/apps/canary
```

Expect: Namespace `canary`, plus `canary-app` Deployment/Service/Ingress in
namespace `canary`, image `ghcr.io/GHCR_OWNER/canary:dev`. kustomize rewrites the
Ingress backend service reference to `canary-app` automatically.

## Apply on a kind cluster

```sh
# once (kind + ingress-nginx):
kind create cluster --name selfheal
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml

# build the canary image and load it into kind (no registry needed for local):
docker build -t canary:dev ./canary
kind load docker-image canary:dev --name selfheal

# point the overlay at the local image for kind, then apply:
#   (edit apps/canary/kustomization.yaml image newName->canary newTag->dev, or
#    override with `kustomize edit set image`)
kubectl apply -k k8s/apps/canary
kubectl -n canary rollout status deploy/canary-app
```

Then either `kubectl -n canary port-forward svc/canary-app 8080:80` and hit
`localhost:8080/work`, or browse `http://canary.127.0.0.1.nip.io/` through the
ingress.

## Before CI can push images

Replace `GHCR_OWNER` in `apps/canary/kustomization.yaml` with your GitHub
username/org. The pipeline (P1) sets the tag automatically per build.

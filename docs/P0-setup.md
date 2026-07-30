# Task #3 — your setup (kind cluster + GitHub repo)

Everything here runs on **your** machine (Windows). It's the one task that
unblocks the whole back half of the project: pipeline, secrets, self-healing.
Budget ~30–45 min. Run in **PowerShell**.

---

## 0. Prerequisites

- **Docker Desktop** running (kind runs the cluster inside a container).
- **git**, and a **GitHub account**.
- Optional but recommended: **GitHub CLI** (`gh`) — makes auth painless, which
  is exactly what stalled Project 1.

---

## 1. Install kubectl + kind

Pick whichever you have. `choco` (as admin PowerShell) is simplest:

```powershell
choco install kubernetes-cli kind -y
```

winget:

```powershell
winget install -e --id Kubernetes.kubectl
winget install -e --id Kubernetes.kind
```

Verify:

```powershell
kubectl version --client
kind version
```

---

## 2. Create the cluster (ingress-ready)

From the project root (`...\Desktop\projects\selfhealing-cicd`):

```powershell
kind create cluster --name selfheal --config kind-config.yaml
kubectl cluster-info --context kind-selfheal
```

Install ingress-nginx (the kind-specific manifest):

```powershell
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod `
  --selector=app.kubernetes.io/component=controller --timeout=120s
```

---

## 3. Build the canary and load it into kind

kind can't see your local Docker images until you load them (no registry needed
for the dev loop):

```powershell
docker build -t canary:dev .\canary
kind load docker-image canary:dev --name selfheal
```

---

## 4. Point the overlay at the local image + apply

For the kind dev loop we use the local `canary:dev` image instead of GHCR. Two
ways — the throwaway one-liner is fine for now:

```powershell
# temporary override just for kind (don't commit this):
kubectl create namespace canary
(kubectl kustomize k8s\apps\canary) `
  -replace 'ghcr.io/GHCR_OWNER/canary:dev','canary:dev' | kubectl apply -f -

kubectl -n canary rollout status deploy/canary-app
```

Verify it's alive:

```powershell
# through the ingress (nip.io resolves to 127.0.0.1):
curl http://canary.127.0.0.1.nip.io/work        # -> ok v=dev

# break it at runtime and watch /work start failing:
curl -Method POST http://canary.127.0.0.1.nip.io/fault/on
curl http://canary.127.0.0.1.nip.io/work         # -> injected fault (status=500)
curl -Method POST http://canary.127.0.0.1.nip.io/fault/off
```

If ingress is fussy on your setup, skip it:

```powershell
kubectl -n canary port-forward svc/canary-app 8080:80
# then hit http://localhost:8080/work in another shell
```

**That's the two verification checks** for tasks #1 and #2 in one go: the canary
runs, and the manifest contract renders + applies.

---

## 5. Create the GitHub repo

With `gh` (recommended — handles the credentials cleanly):

```powershell
gh auth login                      # once, pick HTTPS + browser
cd ...\Desktop\projects\selfhealing-cicd
git init
git add .
git commit -m "Project 10: canary + manifest contract (P0)"
gh repo create selfhealing-cicd --private --source=. --push
```

Prefer the web UI? Create an empty **private** repo named `selfhealing-cicd`,
then:

```powershell
git init
git add .
git commit -m "Project 10: canary + manifest contract (P0)"
git branch -M main
git remote add origin https://github.com/<you>/selfhealing-cicd.git
git push -u origin main
```

Actions is enabled by default on new repos — nothing to do yet. Confirm under the
repo's **Actions** tab that it's on.

---

## Done when

- [ ] `kubectl get pods -n canary` shows `canary-app` pods **Running**
- [ ] `curl .../work` returns `ok`, and `/fault/on` flips it to a 500
- [ ] `selfhealing-cicd` repo exists on GitHub with the code pushed
- [ ] Actions tab is enabled

Once that's true, ping me — I start task #4 (the deploy pipeline), and I'll need
your GitHub username to replace `GHCR_OWNER` in the overlay.

## Tear down later

```powershell
kind delete cluster --name selfheal
```

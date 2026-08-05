# P5 — Provision the prod cluster (Hetzner + k3s)

Move the proven platform from the local kind cluster onto a real, public,
single-node k3s box. Same manifests; the only new things are a real domain, TLS,
and CI reaching the cluster.

**Your part:** the Hetzner account, SSH, payment, DNS, and running these commands.
**My part:** every command and manifest below. Nothing here needs me to touch your
machine.

Budget ~60–90 min. Cost ~€4–5/mo for the box + whatever a domain runs.

Fill in these blanks as you go: `PUBLIC_IP`, `YOUR_DOMAIN`, `YOUR_EMAIL`,
`GHCR_OWNER` (your GitHub username).

---

## 1. Create the server

In the Hetzner Cloud console:

- New project → **Add Server**
- Location: closest to you
- Image: **Ubuntu 24.04**
- Type: **CX22** (2 vCPU / 4 GB) — shared, cheapest that fits
- SSH key: add yours (Settings → SSH keys) so there's no password login
- **Firewall** (create and attach): allow inbound
  - `22/tcp` from **your IP only**
  - `80/tcp` and `443/tcp` from anywhere
  - `6443/tcp` from anywhere (the k8s API — CI needs it; the CI identity is
    least-privilege so blast radius is one namespace)
- Create, and note the **PUBLIC_IP**.

## 2. Point DNS at it

At your domain registrar, add records so the app hosts resolve to the box. A
wildcard is easiest:

```
A   *.YOUR_DOMAIN      PUBLIC_IP
A   YOUR_DOMAIN        PUBLIC_IP
```

Verify (may take a few minutes to propagate):

```powershell
nslookup canary.YOUR_DOMAIN     # should return PUBLIC_IP
```

## 3. Install k3s

SSH in and install k3s. The `--tls-san` flags put the public IP + domain in the
API server cert so your laptop and CI can talk to it by either name:

```bash
ssh root@PUBLIC_IP

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san PUBLIC_IP --tls-san YOUR_DOMAIN" sh -

# confirm
k3s kubectl get nodes            # one Ready node
```

k3s ships **Traefik** (ingress) and **local-path** (storage) — exactly what the
manifests expect.

Copy the kubeconfig to your laptop and fix the server address:

```bash
# on the box:
cat /etc/rancher/k3s/k3s.yaml
```
Copy that to `~/.kube/prod-config` on your laptop, then replace
`https://127.0.0.1:6443` with `https://PUBLIC_IP:6443`. Test from the laptop:

```powershell
$env:KUBECONFIG="$HOME\.kube\prod-config"
kubectl get nodes
```

## 4. Install cert-manager + issuers

```powershell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

# set your email in k8s/prod/cluster-issuer.yaml first, then:
kubectl apply -f k8s\prod\cluster-issuer.yaml
```

## 5. Deploy the platform

Namespaces + monitoring + the CI identity:

```powershell
kubectl apply -k k8s\observability
kubectl apply -f k8s\prod\ci-rbac.yaml       # creates the canary ns + ci-deployer
```

The image ref is already set to `ghcr.io/aadi071/canary` (your account). Just put
your domain into the prod ingress, then deploy the canary (prod overlay):

```powershell
# your domain into the prod ingress:
(Get-Content k8s\prod\canary\patch-ingress-prod.yaml) -replace 'YOUR_DOMAIN','yourdomain.com' | Set-Content k8s\prod\canary\patch-ingress-prod.yaml

kubectl apply -k k8s\prod\canary
kubectl -n canary rollout status deploy/canary-app
```

> The image won't pull yet unless CI has pushed it (step 6) **and** the GHCR
> package is public, or you've added an imagePullSecret. Simplest: after the first
> CI push, make the `canary` package public in your GitHub packages settings.

Verify TLS + routing:

```powershell
curl.exe https://canary.YOUR_DOMAIN/work        # staging cert = browser warning, that's expected
```

Once that works, flip the issuer annotation in `patch-ingress-prod.yaml` from
`letsencrypt-staging` to `letsencrypt-prod`, re-apply, and the warning goes away.

## 6. Wire CI to the cluster

Build a kubeconfig from the least-privilege `ci-deployer` token and hand it to
GitHub Actions. Run against the prod cluster:

```bash
NS=canary
SERVER=https://PUBLIC_IP:6443
TOKEN=$(kubectl -n $NS get secret ci-deployer-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n $NS get secret ci-deployer-token -o jsonpath='{.data.ca\.crt}')

cat > ci.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: prod
  cluster:
    certificate-authority-data: $CA
    server: $SERVER
contexts:
- name: prod
  context: {cluster: prod, namespace: canary, user: ci}
current-context: prod
users:
- name: ci
  user: {token: $TOKEN}
EOF

base64 -w0 ci.kubeconfig    # copy this whole string
```

In the GitHub repo → Settings → Secrets and variables → Actions → **New secret**:

- Name: `KUBE_CONFIG`
- Value: the base64 string above

Now the deploy job stops self-skipping. One change to make first: point the
pipeline's deploy at the **prod** overlay. In `.github/workflows/deploy.yml`,
change the apply step from `k8s/apps/canary` to `k8s/prod/canary` (tell me and I'll
do it — I left it on the kind overlay until the box existed).

Push a commit and watch the Actions run: build → push to GHCR → apply to the box →
rollout status. That's the pipeline going fully live.

## 7. Prove self-healing on the real box

Same demo as local, now against prod (the healer runs in-cluster this time):

```powershell
# controller image ref is already ghcr.io/aadi071/healer; build+push it, then:
kubectl apply -k k8s\controller
kubectl -n canary rollout status deploy/healer

# drive load at https://canary.YOUR_DOMAIN/work, inject a fault, watch it heal:
kubectl -n canary logs deploy/healer -f
```

## Done when

- [ ] `kubectl get nodes` from your laptop shows the k3s node Ready
- [ ] `https://canary.YOUR_DOMAIN/work` serves over real (prod) TLS
- [ ] a git push triggers a green Actions run that deploys to the box
- [ ] the in-cluster healer rolls back a fault on the real cluster

Ping me at any step — especially before the workflow change in step 6, and once you
have your domain + GitHub username so I can finalize the overlays instead of you
sed-replacing placeholders.

# P5 — Provision the prod cluster (Oracle Cloud Always Free, ARM)

Free-forever public k3s box on Oracle's Ampere A1 (ARM). Same platform as the kind
dev loop; the images are now multi-arch so they run on ARM automatically.

Two Oracle-specific things bite everyone — read these first:

1. **"Out of host capacity."** Free ARM instances are in high demand; creation
   often fails with this. Fixes: try a different Availability Domain in the create
   dialog, retry (capacity frees up), or pick a less-busy home region at signup.
   Persistence pays off — it's the #1 reason people give up on Oracle free.
2. **Ubuntu's iptables blocks everything.** Oracle's Ubuntu images ship with
   iptables rules that drop all inbound except SSH — *in addition* to the cloud
   firewall. Your ingress will look broken until you open ports at BOTH layers.
   Step 4 handles it.

Fill in: `PUBLIC_IP`, `YOUR_DOMAIN`, `YOUR_EMAIL`. Your GitHub username is already
baked into the manifests (`aadi071`).

---

## 1. Sign up

console.oracle.com → create a Free Tier account. Needs a card for identity
verification (Always Free resources are never charged). **Choose your home region
carefully** — it's permanent, and ARM capacity varies by region. A larger region
near you is usually a safer bet for capacity.

## 2. Create the ARM instance

Compute → Instances → **Create instance**:

- Image: **Ubuntu 22.04** (or 24.04)
- Shape: **Ampere / VM.Standard.A1.Flex**, **2 OCPU / 12 GB** (the Always Free max)
- Add your **SSH public key** (`~/.ssh/id_ed25519.pub`; generate with
  `ssh-keygen -t ed25519` if needed)
- Networking: let it create a new VCN + public subnet, **assign a public IPv4**
- Create. If you hit "out of host capacity," switch the Availability Domain
  dropdown and retry, or come back in a bit.

Note the **PUBLIC_IP**.

## 3. Open ports in the VCN (cloud firewall)

Networking → your VCN → the public subnet's **Security List** → add **Ingress
Rules** (Source `0.0.0.0/0`, IP Protocol TCP), one per destination port:

- `80`, `443` (web/TLS), `6443` (k8s API, for CI). `22` is already open.

## 4. Open ports on the host (the gotcha)

SSH in and punch through Ubuntu's local iptables, or the VCN rules alone won't be
enough:

```bash
ssh ubuntu@PUBLIC_IP     # Oracle Ubuntu user is "ubuntu", not root

sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 6443 -j ACCEPT
sudo netfilter-persistent save
```

## 5. Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san PUBLIC_IP --tls-san YOUR_DOMAIN" sh -
sudo k3s kubectl get nodes        # one Ready arm64 node
```

Copy the kubeconfig to your laptop:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```
Save as `~/.kube/prod-config` on your laptop, replace `https://127.0.0.1:6443`
with `https://PUBLIC_IP:6443`, then:

```powershell
$env:KUBECONFIG="$HOME\.kube\prod-config"
kubectl get nodes                 # arm64 node Ready
```

## 6. DNS

Point records at the box (wildcard is easiest):

```
A   *.YOUR_DOMAIN   PUBLIC_IP
A   YOUR_DOMAIN     PUBLIC_IP
```

## 7. cert-manager + issuers

```powershell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
# set YOUR_EMAIL in k8s/prod/cluster-issuer.yaml, then:
kubectl apply -f k8s\prod\cluster-issuer.yaml
```

## 8. Deploy the platform

```powershell
kubectl apply -k k8s\observability
kubectl apply -f k8s\prod\ci-rbac.yaml

# your domain into the prod ingress:
(Get-Content k8s\prod\canary\patch-ingress-prod.yaml) -replace 'YOUR_DOMAIN','yourdomain.com' | Set-Content k8s\prod\canary\patch-ingress-prod.yaml
kubectl apply -k k8s\prod\canary
kubectl -n canary rollout status deploy/canary-app
```

The images are multi-arch, so k3s pulls the arm64 variant automatically. First
pull needs CI to have pushed (step 9) and the GHCR package to be public (make the
`canary` package public in GitHub → Packages after the first push).

Verify: `curl.exe https://canary.YOUR_DOMAIN/work` (staging cert = browser warning,
expected). Then flip `letsencrypt-staging` → `letsencrypt-prod` in the ingress
patch, re-apply, and the warning clears.

## 9. Wire CI to the cluster

Build the least-privilege kubeconfig and add it as a GitHub secret:

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
  cluster: {certificate-authority-data: $CA, server: $SERVER}
contexts:
- name: prod
  context: {cluster: prod, namespace: canary, user: ci}
current-context: prod
users:
- name: ci
  user: {token: $TOKEN}
EOF
base64 -w0 ci.kubeconfig
```

GitHub repo → Settings → Secrets and variables → Actions → new secret
`KUBE_CONFIG` = that base64 string.

Then tell me to flip the pipeline's deploy step from `k8s/apps/canary` to
`k8s/prod/canary`, push, and watch Actions build the multi-arch image, push to
GHCR, and deploy to the ARM box.

## Done when

- [ ] `kubectl get nodes` shows the arm64 node Ready from your laptop
- [ ] `https://canary.YOUR_DOMAIN/work` serves over prod TLS
- [ ] a push triggers a green Actions run that deploys to Oracle
- [ ] the in-cluster healer rolls back a fault on the real box

Ping me at any step — the two most likely snags are capacity (step 2) and the host
iptables (step 4).

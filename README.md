# k3s-bootstrap

Local Kubernetes development environment using Colima + k3s with ArgoCD and Envoy Gateway.

## Dependencies

```bash
brew install colima docker docker-credential-helper kubectl jq mkcert argocd helm
```

## Usage

```bash
./start.sh           # normal run
./start.sh --debug   # with trace output

## Endpoints
* ArgoCD: https://argocd.kube.local
* VictoriaMetrics: https://metrics.kube.local
```

## What it does

### Phase 1: Infrastructure
- Starts Colima VM with k3s (`--network-address` for static IP)
- Waits for node and CoreDNS readiness

### Phase 2: DNS + TLS
- Patches CoreDNS to resolve `*.kube.local` → Colima VM IP
- Exposes CoreDNS via NodePort 30053
- Configures macOS `/etc/resolver/kube.local`
- Generates trusted wildcard TLS cert (`*.kube.local`) via mkcert
- Trusts CA in login keychain only (no system pollution)

### Phase 3: ArgoCD
- Deploys ArgoCD to `argocd` namespace via kustomize
- Two-pass apply to bootstrap CRDs before Application resources
- Extracts ArgoCD server CA for backend TLS re-encryption

### Phase 4: Applications (ArgoCD sync waves)

| Wave | Application | What it deploys |
|------|-------------|-----------------|
| 0 | `envoy-gateway` | Envoy Gateway + Gateway API CRDs (Helm) |
| 1 | `envoy-argocd-routes` | Gateway, HTTPRoutes, TLS policies |

### Phase 5: Ready
- Authenticates ArgoCD CLI
- Opens `https://argocd.kube.local` in browser

## Architecture

```
Browser → http://argocd.kube.local → 301 redirect
Browser → https://argocd.kube.local
        → Envoy Gateway (terminates TLS with mkcert wildcard)
        → ArgoCD server (re-encrypts to self-signed)
```

## Project structure

```
start.sh                          # Bootstrap script
argocd-bootstrap/
  kustomization.yml               # ArgoCD + app-of-apps
  app-of-apps.yaml                # Parent Application
  applications/
    envoy-gateway.yaml            # Wave 0: Envoy Gateway Helm chart
    envoy-argocd-routes.yaml      # Wave 1: routing resources
envoy-routes/
  gateway.yaml                    # GatewayClass + Gateway + HTTP→HTTPS redirect
  argocd-routes.yaml              # HTTPRoutes for ArgoCD
  argocd-backend-tls.yaml         # ReferenceGrant + BackendTLSPolicy
.ca/                              # mkcert CA (gitignored)
```

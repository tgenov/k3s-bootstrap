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
```
## Endpoints

* ArgoCD: https://argocd.kube.local
* VictoriaMetrics: https://metrics.kube.local

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

### Phase 4: Applications (ArgoCD managed)

| Application | What it deploys |
|-------------|-----------------|
| `envoy-gateway` | Envoy Gateway + Gateway API CRDs (Helm) |
| `envoy-argocd-routes` | Gateway, HTTPRoutes, TLS policies |
| `monitoring-stack` | VictoriaMetrics + ArgoCD metrics scraping |

### Phase 5: Ready
- Authenticates ArgoCD CLI
- Opens `https://argocd.kube.local` in browser

## Architecture

```
Browser → http://*.kube.local → 301 redirect
Browser → https://argocd.kube.local
        → Envoy Gateway (terminates TLS with mkcert wildcard)
        → ArgoCD server (re-encrypts to self-signed)

Browser → https://metrics.kube.local
        → Envoy Gateway (terminates TLS)
        → VictoriaMetrics (scrapes ArgoCD metrics)
```

## Project structure

```
start.sh                          # Bootstrap script
argocd-bootstrap/
  kustomization.yml               # ArgoCD + applications
  applications/
    envoy-gateway.yaml            # Envoy Gateway Helm chart
    envoy-argocd-routes.yaml      # Routing resources
    monitoring-stack.yaml         # VictoriaMetrics application
envoy-routes/
  gateway.yaml                    # GatewayClass + Gateway + HTTP→HTTPS redirect
  argocd-routes.yaml              # HTTPRoutes for ArgoCD
  argocd-backend-tls.yaml         # ReferenceGrant + BackendTLSPolicy
monitoring-stack/
  kustomization.yaml              # Kustomize config
  namespace.yaml                  # monitoring namespace
  vmsingle.yaml                   # VictoriaMetrics deployment + service
  scrape-config.yaml              # Prometheus scrape configs for ArgoCD
  httproute.yaml                  # HTTPRoute for metrics.kube.local
.ca/                              # mkcert CA (gitignored)
```

#!/bin/bash
set -o pipefail
set -eu

[[ "${1:-}" == "--debug" ]] && set -x

# Start colima (skip if already running)
if ! colima status 2>/dev/null | grep -q Running; then
  colima start -c 8 -m 10 -d 160 -k --kubernetes-version v1.34.3+k3s1 --network-address
fi
IP=$(colima status --json | jq -r '.ip_address')

# Wait for k3s to be ready
echo "Waiting for k3s node to be ready..."
until kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 2
done
echo "k3s node ready"

# Wait for CoreDNS to be running
echo "Waiting for CoreDNS..."
until kubectl -n kube-system get deploy/coredns 2>/dev/null; do
  sleep 2
done
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

# Patch CoreDNS to resolve *.kube.local and fix upstream DNS forwarding
echo "Patching CoreDNS to resolve *.kube.local -> $IP"
kubectl -n kube-system get configmap coredns -o json | jq --arg ip "$IP" '
  .data.Corefile |= (
    gsub("forward \\. [^\n]+"; "forward . 8.8.8.8 1.1.1.1") |
    split("\nkube.local:53")[0] + "\nkube.local:53 {\n    template IN A {\n        match .*[.]kube[.]local[.]$\n        answer \"{{ .Name }} 60 IN A \($ip)\"\n        fallthrough\n    }\n}\n"
  )
' | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=60s
echo "CoreDNS patched: *.kube.local -> $IP"

# Expose CoreDNS via NodePort on 30053
echo "Creating CoreDNS NodePort service on port 30053..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: coredns-external
  namespace: kube-system
spec:
  type: NodePort
  selector:
    k8s-app: kube-dns
  ports:
    - name: dns-udp
      protocol: UDP
      port: 53
      targetPort: 53
      nodePort: 30053
    - name: dns-tcp
      protocol: TCP
      port: 53
      targetPort: 53
      nodePort: 30053
EOF

# Configure macOS resolver for .kube.local domain
echo "Configuring /etc/resolver/kube.local -> $IP:30053"
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/kube.local >/dev/null <<EOF
domain kube.local
nameserver $IP
port 30053
EOF
echo "macOS resolver configured for .kube.local"

# Generate trusted wildcard TLS certificate for *.kube.local
echo "Generating trusted wildcard certificate for *.kube.local..."
export CAROOT="$(cd "$(dirname "$0")" && pwd)/.ca"
mkdir -p "$CAROOT"
CERT_DIR="$(mktemp -d)"
mkcert -cert-file "$CERT_DIR/tls.crt" -key-file "$CERT_DIR/tls.key" "*.kube.local"
mkcert -uninstall 2>/dev/null || true
if ! security find-certificate -c "mkcert" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  security add-trusted-cert -k ~/Library/Keychains/login.keychain-db "$CAROOT/rootCA.pem"
fi
kubectl -n default create secret tls kube-local-tls \
  --cert="$CERT_DIR/tls.crt" \
  --key="$CERT_DIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$CERT_DIR"
echo "TLS secret 'kube-local-tls' created"

# Deploy ArgoCD and applications
echo "Deploying ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace argocd gateway-access=true --overwrite
# Two-pass apply: first installs ArgoCD CRDs, second applies Application resources
kubectl apply -k argocd-bootstrap/ 2>&1 | grep -v "no matches for kind" || true
kubectl apply -k argocd-bootstrap/
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
# Force immediate sync instead of waiting for the 3-minute poll cycle
kubectl -n argocd annotate application envoy-gateway argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd annotate application envoy-argocd-routes argocd.argoproj.io/refresh=hard --overwrite

# Extract ArgoCD's self-signed CA for BackendTLSPolicy
echo "Creating ArgoCD CA ConfigMap for backend TLS..."
until kubectl -n argocd get secret argocd-secret 2>/dev/null; do
  sleep 2
done
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.tls\.crt}' | base64 -d >/tmp/argocd-ca.crt
kubectl -n argocd create configmap argocd-server-ca \
  --from-file=ca.crt=/tmp/argocd-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/argocd-ca.crt
echo "ArgoCD backend TLS configured"

# Wait for Envoy Gateway and routes to be fully deployed
echo "Waiting for Envoy Gateway and routes to sync..."
until kubectl -n argocd get application envoy-argocd-routes 2>/dev/null; do
  sleep 5
done
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/envoy-gateway --timeout=300s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/envoy-argocd-routes --timeout=300s

# Wait for Envoy to be serving argocd.kube.local
echo "Waiting for https://argocd.kube.local to become reachable..."
until curl -skf -o /dev/null --max-time 2 https://argocd.kube.local; do
  sleep 3
done
echo "argocd.kube.local is reachable"

# Open ArgoCD web UI
echo "Opening ArgoCD web UI..."
echo "  URL: https://argocd.kube.local"
open "https://argocd.kube.local"

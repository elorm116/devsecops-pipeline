#!/bin/bash
echo "Checking K3s Node Status..."
kubectl get nodes

echo "Checking Cloudflare Tunnel..."
# Replace 'victor-tunnel' with your actual tunnel name or ID
cloudflared tunnel info victor-tunnel

echo "Checking ArgoCD Sync Status..."
# Since you're local, this uses the port-forward or the internal API
argocd app list --server localhost:8080 --plaintext
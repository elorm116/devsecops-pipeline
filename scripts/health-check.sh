#!/bin/bash
echo "Checking K3s Node Status..."
kubectl get nodes

echo "Checking Cloudflare Tunnel..."
cloudflared tunnel status

echo "Checking ArgoCD Sync Status..."
argocd app list
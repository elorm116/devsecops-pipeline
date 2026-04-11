#!/bin/bash

echo "--- 🛡️ K3s Node Status ---"
kubectl get nodes

echo -e "\n--- ☁️ Cloudflare Tunnel (Victor) ---"
# Using your actual tunnel name: Victor
cloudflared tunnel info Victor

echo -e "\n--- 🐙 ArgoCD Sync Status ---"
# This checks if the port-forward is running before trying to connect
if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null ; then
    argocd app list --server localhost:8080 --plaintext
else
    echo "⚠️ Error: Port-forward to ArgoCD not detected."
    echo "Run: kubectl port-forward svc/argocd-server -n argocd 8080:443"
fi
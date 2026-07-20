#!/usr/bin/env bash
# One-time bootstrap: after Terraform has created the EKS cluster and
# installed ArgoCD (terraform/argocd-bootstrap.tf), this script applies
# the root "app of apps" Application. From that point on, ArgoCD manages
# itself and every environment purely from git -- this script never needs
# to run again unless you're standing up a brand new cluster.
set -euo pipefail

CLUSTER_NAME="${1:-gitops-demo}"
AWS_REGION="${2:-us-east-1}"

echo ">> Updating kubeconfig for cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

echo ">> Waiting for ArgoCD server to be ready..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo ">> Applying AppProject..."
kubectl apply -f argocd/projects/gitops-demo-project.yaml

echo ">> Applying root app-of-apps Application..."
kubectl apply -f argocd/app-of-apps.yaml

echo ">> Fetching initial ArgoCD admin password..."
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
echo ">> Bootstrap complete. Port-forward the UI with:"
echo "   kubectl -n argocd port-forward svc/argocd-server 8080:443"

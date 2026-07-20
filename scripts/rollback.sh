#!/usr/bin/env bash
# Emergency rollback. Two layers, use whichever matches the situation:
#
#  1. Rollout-level (fast, seconds): abort the in-flight canary and shift
#     all traffic back to the last stable ReplicaSet. Use this first.
#
#  2. Git-level (source of truth, minutes): revert the promotion commit so
#     the desired state in git matches what you just rolled back to,
#     otherwise ArgoCD's self-heal will silently re-apply the bad version.
set -euo pipefail

ENVIRONMENT="${1:?usage: rollback.sh <staging|prod>}"

echo ">> [1/2] Aborting rollout in namespace ${ENVIRONMENT}..."
kubectl argo rollouts abort gitops-demo-app -n "${ENVIRONMENT}"
kubectl argo rollouts undo gitops-demo-app -n "${ENVIRONMENT}"

echo ">> [2/2] Reminder: revert the promotion commit so git matches reality:"
echo "   git log --oneline -- k8s/overlays/${ENVIRONMENT}/kustomization.yaml"
echo "   git revert <bad-promotion-commit-sha>"
echo "   git push   # ArgoCD will sync the reverted (old) image tag"

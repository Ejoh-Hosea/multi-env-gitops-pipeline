# Architecture

## High-level flow

```
 ┌─────────────┐   push to main    ┌────────────────────────────┐
 │  Developer  │ ────────────────► │  ci.yaml (GitHub Actions)  │
 └─────────────┘                   │  test → build → scan → push │
                                    └───────────────┬────────────┘
                                                     │ image ghcr.io/.../app:sha
                                                     ▼
                                    ┌────────────────────────────┐
                                    │  commit: bump dev tag        │
                                    │  k8s/overlays/dev/            │
                                    │  kustomization.yaml            │
                                    └───────────────┬────────────┘
                                                     │ ArgoCD polls/webhook
                                                     ▼
                              ┌──────────────────────────────────────┐
                              │  ArgoCD Application: gitops-demo-app-dev │
                              │  syncPolicy.automated (auto + selfHeal)   │
                              └───────────────┬──────────────────────┘
                                               ▼
                                        namespace: dev
                                        Rollout: 0->100% instantly


 ┌─────────────┐  promote.sh staging <tag>   ┌──────────────────────┐
 │  Engineer   │ ───────────────────────────►│ promote.yaml           │
 └─────────────┘                             │ opens PR: bump staging  │
                                              │ image tag                │
                                              └──────────┬────────────┘
                                                          │ human review + merge
                                                          ▼
                                              ┌──────────────────────┐
                                              │ promote-deploy.yaml     │
                                              │ job: deploy-staging       │
                                              │ environment: staging        │
                                              │ (1 reviewer gate)             │
                                              └──────────┬────────────┘
                                                          │ argocd app sync
                                                          ▼
                              ┌──────────────────────────────────────┐
                              │ ArgoCD Application: gitops-demo-app-staging│
                              └───────────────┬──────────────────────┘
                                               ▼
                                     namespace: staging
                                     Rollout: canary 25%→50%→100%
                                     + AnalysisTemplate (Prometheus)


 ┌─────────────┐  promote.sh prod <tag>      ┌──────────────────────┐
 │  Engineer   │ ───────────────────────────►│ promote.yaml           │
 └─────────────┘                             │ opens PR: bump prod      │
                                              │ image tag (CODEOWNERS)    │
                                              └──────────┬────────────┘
                                                          │ platform-team review + merge
                                                          ▼
                                              ┌──────────────────────┐
                                              │ promote-deploy.yaml     │
                                              │ job: deploy-prod           │
                                              │ environment: production      │
                                              │ (2 reviewers + 5min wait)      │
                                              └──────────┬────────────┘
                                                          │ argocd app sync
                                                          ▼
                              ┌──────────────────────────────────────┐
                              │ ArgoCD Application: gitops-demo-app-prod   │
                              │ syncPolicy: MANUAL (no automated block)     │
                              └───────────────┬──────────────────────┘
                                               ▼
                                     namespace: prod
                                     Rollout: canary 10%→[MANUAL GATE]
                                     →25%→50%→100% + AnalysisTemplate
```

## Component responsibilities

| Component | Responsibility | Where it lives |
|---|---|---|
| GitHub Actions (`ci.yaml`) | Test, build, vulnerability-scan, push image; auto-update dev overlay | `.github/workflows/ci.yaml` |
| GitHub Actions (`promote.yaml`) | Open a reviewable PR that bumps an overlay's image tag — never deploys directly | `.github/workflows/promote.yaml` |
| GitHub Actions (`promote-deploy.yaml`) | Gate on GitHub Environment approval, then trigger `argocd app sync` | `.github/workflows/promote-deploy.yaml` |
| Kustomize base | Single source of truth for the Rollout/Service/ConfigMap/AnalysisTemplate shape | `k8s/base/` |
| Kustomize overlays | Per-environment patches: replica count, canary strategy, image tag | `k8s/overlays/{dev,staging,prod}/` |
| ArgoCD AppProject | RBAC boundary: which repos/namespaces/resource kinds are allowed | `argocd/projects/` |
| ArgoCD Applications | One per environment; owns the actual sync policy (auto vs. manual) | `argocd/apps/` |
| Argo Rollouts | Executes canary steps, pauses, and automated analysis in-cluster | `k8s/base/rollout.yaml` |
| AnalysisTemplate | Prometheus query Argo Rollouts uses to auto-abort a bad canary | `k8s/base/analysis-template.yaml` |
| Terraform | VPC, EKS cluster, IRSA, and Helm-installs ArgoCD/Rollouts/Prometheus | `terraform/` |
| kube-prometheus-stack | Supplies the metrics the AnalysisTemplate queries, plus Grafana dashboards | installed via `terraform/argocd-bootstrap.tf` |

## Environment comparison

| | Dev | Staging | Prod |
|---|---|---|---|
| Trigger | every merge to `main` (auto) | `promote.sh staging` → PR → merge | `promote.sh prod` → PR → merge |
| PR review required | no (direct commit by CI) | yes, 1 reviewer | yes, `@platform-team` (CODEOWNERS) |
| GitHub Environment gate | none | `staging`: 1 reviewer | `production`: 2 reviewers + 5 min wait |
| ArgoCD sync policy | automated + selfHeal | automated + selfHeal | manual only |
| Rollout strategy | 0→100% instantly | canary, 1 min pauses | canary, 5 min pauses + manual pause at 10% |
| Automated analysis | none | yes (Prometheus error rate) | yes (Prometheus error rate) |
| Replicas | 1 | 3 | 5 |
| PodDisruptionBudget | no | no | yes (`minAvailable: 2`) |

## Failure-path diagram: bad canary in prod

```
Rollout at 25% weight
        │
        ▼
AnalysisTemplate queries Prometheus every 30s
        │
        ├─ error rate < 5% (3 consecutive checks) ──► proceed to next step
        │
        └─ error rate >= 5% ──► failureLimit reached
                                        │
                                        ▼
                          Argo Rollouts auto-aborts
                          traffic shifts back to stable ReplicaSet
                                        │
                                        ▼
                    git still points at the bad tag (cluster != git desired state)
                                        │
                                        ▼
                    engineer runs scripts/rollback.sh prod
                    → confirms live traffic is on stable version
                    → git revert the promotion commit
                    → push (ArgoCD now reconciles to the reverted, good tag)
```

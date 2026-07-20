# Multi-Environment GitOps Pipeline (Dev → Staging → Prod)

A complete, runnable reference implementation of a GitOps delivery
pipeline: one container image is built once, then **promoted** unchanged
across dev, staging, and production, with progressively stricter approval
gates and canary deployments at each stage.

```
commit → CI (test, build, scan, push) → auto-deploy to DEV
                                              │
                                   promote.sh │ opens reviewed PR
                                              ▼
                                    STAGING (canary + auto analysis)
                                              │
                                   promote.sh │ opens reviewed PR
                                              ▼
                          PROD (canary + auto analysis + manual gate)
```

📄 **Read [`docs/EXPLANATIONS.md`](docs/EXPLANATIONS.md) for a full
walkthrough of *why* the pipeline is designed this way** — the reasoning
behind every architectural decision, the approval-gate mechanics, and
trade-offs. Start with this README for setup; go to that doc to actually
understand the system.

📄 See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for component
diagrams and data flow.

---

## What this project demonstrates

- **GitOps** with ArgoCD (app-of-apps pattern, one Application per environment)
- **Progressive delivery** with Argo Rollouts (canary steps + automated
  Prometheus-based analysis + manual promotion gate in prod)
- **CI/CD** with GitHub Actions (test → build → scan → push → auto-deploy dev)
- **Two independent approval gates** for staging/prod: reviewed Pull
  Requests (branch protection + CODEOWNERS) and GitHub Environment
  protection rules (required reviewers before a deploy job can run)
- **Infrastructure as Code** with Terraform (VPC, EKS, IRSA, Helm-installed
  ArgoCD/Argo Rollouts/kube-prometheus-stack)
- **Kustomize** overlays so dev/staging/prod share one base manifest set
  and only differ in what's explicitly patched
- **Observability** with Prometheus/Grafana, used both for dashboards and
  as the automated analysis signal that gates canary promotion

## Repository structure

```
.
├── app/                      # Demo Node.js microservice + Dockerfile + tests
├── terraform/                 # VPC, EKS, IRSA, ArgoCD/Rollouts/Prometheus bootstrap
├── k8s/
│   ├── base/                    # Rollout, Service, ConfigMap, AnalysisTemplate
│   └── overlays/{dev,staging,prod}/  # Per-environment patches + image tags
├── argocd/
│   ├── projects/                # AppProject (RBAC boundary)
│   ├── apps/                    # One Application manifest per environment
│   └── app-of-apps.yaml         # Root Application (bootstraps the other 3)
├── .github/workflows/
│   ├── ci.yaml                    # test → build → scan → push → deploy dev
│   ├── promote.yaml                # opens a promotion PR (staging/prod)
│   └── promote-deploy.yaml          # environment-gated ArgoCD sync after merge
├── scripts/                    # bootstrap.sh, promote.sh, rollback.sh
└── docs/
    ├── EXPLANATIONS.md            # design rationale, deep dive (start here)
    └── ARCHITECTURE.md             # diagrams, component breakdown
```

## Prerequisites

- AWS account with permission to create VPC/EKS/IAM resources
- Terraform >= 1.6
- `kubectl`, `helm`, the [`argo rollouts` kubectl
  plugin](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation),
  and the [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)
- GitHub CLI (`gh`) for the promotion scripts
- A GitHub repo with:
  - Branch protection on `main` requiring 1+ review
  - Two [GitHub
    Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
    named `staging` (1 required reviewer) and `production` (2 required
    reviewers + a 5 minute wait timer)
  - Repo secrets: `GITOPS_PAT`, `ARGOCD_SERVER`, `ARGOCD_AUTH_TOKEN`

## Quickstart

```bash
# 1. Bootstrap remote state (one-time, out of band)
aws s3 mb s3://REPLACE-ME-gitops-demo-tfstate
aws dynamodb create-table --table-name REPLACE-ME-gitops-demo-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 2. Provision the cluster + install ArgoCD/Argo Rollouts/Prometheus
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply

# 3. Bootstrap the app-of-apps (one-time; ArgoCD manages everything after this)
cd ..
./scripts/bootstrap.sh gitops-demo us-east-1

# 4. Push a change under app/ to main -> watch CI deploy to dev automatically
kubectl -n dev get rollout gitops-demo-app --watch

# 5. Promote a known-good tag to staging, then prod
./scripts/promote.sh staging <image-tag>
#   -> review + merge the opened PR
#   -> approve the "staging" environment gate in the Actions tab
./scripts/promote.sh prod <image-tag>
#   -> review + merge the opened PR (requires @platform-team per CODEOWNERS)
#   -> approve the "production" environment gate (2 reviewers, 5 min wait)
kubectl argo rollouts get rollout gitops-demo-app -n prod --watch
kubectl argo rollouts promote gitops-demo-app -n prod   # clear the manual pause step
```

## Rollback

```bash
./scripts/rollback.sh staging   # or prod
```
See [`docs/EXPLANATIONS.md#rollback`](docs/EXPLANATIONS.md#rollback-strategy)
for why this is a two-step (Rollout abort + git revert) process.

## Cleanup

```bash
cd terraform
terraform destroy
```

## License

MIT — this is a portfolio/reference project, adapt freely.

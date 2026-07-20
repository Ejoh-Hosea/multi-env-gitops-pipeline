# Explanations: Design Rationale for the Multi-Environment GitOps Pipeline

This document explains **why** the pipeline is built the way it is. If the
README is "how to run it," this is "why it works this way" — the reasoning
you'd want to be able to defend in an interview or a design review.

---

## 1. What problem is this actually solving?

Naively, "CI/CD to Kubernetes" can be done with a single script: build an
image, `kubectl apply` it, done. That breaks down once you have more than
one environment and more than one person, for a few concrete reasons:

- **Drift.** If deployment happens by someone running `kubectl apply` or
  `helm upgrade` from their laptop, the cluster's actual state and the
  repo's declared state diverge over time. Nobody can answer "what's
  actually running in prod?" with confidence.
- **No audit trail on *infrastructure* changes.** Application code changes
  go through PR review. Deployment changes (image tags, replica counts,
  resource limits) often don't — they happen via ad hoc `kubectl` commands
  that leave no reviewable history.
- **No safe way to gate risk.** Dev should deploy on every commit. Prod
  should not. A single pipeline with one policy can't express that
  difference well.
- **No automatic detection of a bad release.** If deploys are "apply and
  hope," a bad release is caught only when a human notices, which is slow
  and inconsistent.

GitOps solves the first two by making **git the single source of truth**
for desired state, with an in-cluster controller (ArgoCD) continuously
reconciling actual state to match it. Progressive delivery (Argo Rollouts)
solves the third and fourth by shifting traffic gradually and
automatically analyzing metrics as it goes.

---

## 2. Why ArgoCD (pull-based) instead of a CI tool pushing to the cluster?

Two models exist:

- **Push-based**: CI (GitHub Actions/Jenkins) holds cluster credentials
  and runs `kubectl apply`/`helm upgrade` directly against the cluster.
- **Pull-based (GitOps)**: an in-cluster agent (ArgoCD) watches a git repo
  and reconciles the cluster to match it. CI never touches the cluster
  directly — it only changes what's *in git*.

This project uses pull-based, because:

1. **No cluster credentials leave the cluster.** CI needs zero
   `kubeconfig`/cluster access for day-to-day deploys — it only needs
   registry push access and git write access. This shrinks the blast
   radius of a compromised CI pipeline significantly.
2. **Self-healing.** ArgoCD's `selfHeal: true` continuously corrects
   manual drift (someone `kubectl edit`-ing a Deployment by hand) back to
   what git says. Push-based pipelines have no equivalent unless you build
   one yourself.
3. **The cluster can be entirely private (no public API endpoint) and
   GitOps still works**, since the agent living inside the cluster
   initiates the connection outward to git, not the other way around.
   (This demo does expose a public EKS endpoint for simplicity — see
   `terraform/eks.tf` — but the architecture doesn't require it.)

The trade-off: an extra moving part (ArgoCD itself) to operate, and a
slightly less immediate feedback loop (reconciliation is polling/webhook
driven rather than synchronous with the CI run). Both are considered
acceptable for the durability and security benefits.

---

## 3. Why Kustomize overlays instead of Helm for the k8s manifests, or separate raw YAML per environment?

Three real options:

- **Copy-pasted raw YAML per environment** — simplest to read, but drifts:
  a fix applied to staging's Service definition is easily forgotten in
  prod's copy.
- **Helm** — powerful templating, the de facto standard for third-party
  charts (and this project *does* use Helm for third-party components —
  ArgoCD, Argo Rollouts, kube-prometheus-stack — in `terraform/argocd-bootstrap.tf`).
  For an application you own, though, Helm's templating language
  (Go templates + values.yaml) adds a layer of indirection that's often
  unnecessary and harder to diff/review in a PR.
- **Kustomize** — a strict base + declarative patches. There is exactly
  one source of truth (`k8s/base/`) and each environment overlay
  (`k8s/overlays/{dev,staging,prod}/`) contains *only what's different*:
  replica count, canary strategy, image tag, an extra PodDisruptionBudget
  in prod. Diffing two overlays' `kustomization.yaml` tells you precisely
  what differs between environments — which is exactly the question a
  reviewer asks on a promotion PR.

Kustomize was chosen because the promotion workflow in this project is
built around small, reviewable, plain-text diffs to `kustomization.yaml`
(see `scripts/promote.sh` → `promote.yaml` workflow). That property is
harder to get with Helm's `--set` overrides or a templated values file
without extra tooling.

---

## 4. Why Argo Rollouts (canary) instead of a plain Kubernetes Deployment with `RollingUpdate`?

A standard `Deployment`'s `RollingUpdate` strategy shifts traffic to new
pods as soon as they pass their readiness probe — usually within seconds
— with no concept of "watch error rates for a while before going further."
It answers "is the pod up?" not "is the pod *good*?"

Argo Rollouts (`k8s/base/rollout.yaml`) replaces `Deployment` with
`Rollout`, which adds:

- **Weighted traffic steps** (`setWeight: 20`, `50`, `100`) instead of an
  all-or-nothing cutover.
- **Pauses between steps**, either timed (`pause: {duration: 5m}`) or
  indefinite (`pause: {}`) requiring a human to run `kubectl argo rollouts
  promote`.
- **Automated Analysis** (`k8s/base/analysis-template.yaml`): a
  Prometheus query is run on a schedule during the rollout; if the error
  rate crosses the configured threshold, Argo Rollouts automatically
  aborts and rolls traffic back to the last known-good ReplicaSet —
  without anyone needing to be watching a dashboard in real time.

This is layered with increasing strictness by environment (see the
overlay `rollout-patch.yaml` files):

| Environment | Steps | Analysis | Manual gate |
|---|---|---|---|
| dev | 0 → 100% immediately | none | none |
| staging | 25% → 50% → 100%, 1 min pauses | yes | none |
| prod | 10% → 25% → 50% → 100%, 5 min pauses | yes | yes, at 10% |

Dev intentionally has *no* safety net — the entire point of dev is fast
feedback, and a bad dev deploy costs nothing. Prod has the most steps, the
longest bake time, and a hard manual gate, because the cost of a bad prod
release is highest.

---

## 5. How the two approval gates for staging/prod actually work (this is the part people usually get vague about)

"Approval gates" here means two genuinely independent mechanisms, both of
which must pass before code reaches staging/prod. It is not just "click
approve in Slack."

**Gate 1 — Pull Request review (`promote.yaml` → a PR).**
Running `./scripts/promote.sh prod <tag>` doesn't deploy anything. It
triggers a workflow that edits `k8s/overlays/prod/kustomization.yaml`
(bumping the image tag) and opens a PR with that single, easy-to-review
diff. Branch protection on `main` requires at least one approval before
merge; `.github/CODEOWNERS` additionally requires `@platform-team`
specifically for anything under `k8s/overlays/prod/`. This gate lives
entirely in git/GitHub — it's the same review mechanism as any other code
change, which means promotion history is just... commit history. `git log
-- k8s/overlays/prod/kustomization.yaml` is your deployment audit log,
for free.

**Gate 2 — GitHub Environment protection (`promote-deploy.yaml`).**
Merging the PR from Gate 1 changes what's in git, but — critically —
ArgoCD's `Application` for prod (`argocd/apps/app-prod.yaml`) has **no
automated sync policy**. Nothing deploys yet. Merging main also triggers
`promote-deploy.yaml`, whose `deploy-prod` job declares `environment:
production`. GitHub Environments can be configured (in repo Settings, not
in this codebase — see README prerequisites) with required reviewers and
a wait timer; the job's steps *do not start running* until that
protection rule clears. Only once the job actually runs does it execute
`argocd app sync gitops-demo-app-prod`, which is what finally tells
ArgoCD to reconcile the cluster.

Why two gates instead of one? They protect against different failure
modes:
- PR review catches "is this the right change" (wrong tag, wrong overlay,
  unreviewed config drift).
- The Environment gate catches "is *right now* a safe time to deploy this"
  (e.g., someone approves a PR at 2pm but the actual production push
  should wait for a lower-traffic window, or a second person needs to
  independently confirm right before the button is pressed). It also
  means merging a PR is not itself an irreversible trigger — there's a
  deliberate, separate, revocable action between "code review passed" and
  "traffic is shifting in prod."

Staging uses only a lighter version of Gate 2 (1 reviewer, no wait timer)
since the risk profile is lower and staging is itself a safety net for
prod.

---

## 6. Why "build once, promote the artifact" instead of rebuilding per environment?

`app/Dockerfile` and `ci.yaml` build exactly one image per commit,
tagged with a short git SHA, pushed once to GHCR. Promotion
(`promote.yaml`) never rebuilds — it only changes which existing,
already-tested, already-scanned image tag an overlay points at.

This matters because if staging and prod were built from separate
`docker build` invocations (even from the same Dockerfile/source), you
lose the guarantee that what passed testing in staging is bit-for-bit
identical to what runs in prod — different base image patch versions
pulled at build time, different `npm install` resolution, etc. can all
silently change behavior. "Build once, deploy everywhere" is what makes a
green staging canary actually predictive of prod behavior.

---

## 7. Why one EKS cluster with three namespaces, not three separate clusters?

This reference implementation uses a **single EKS cluster** with
`dev`/`staging`/`prod` as namespaces (see `k8s/overlays/*/namespace.yaml`
and the single `module "eks"` in `terraform/eks.tf`), not three clusters.

**In favor of namespaces (what this repo does):**
- Much lower cost and operational overhead for a demo/portfolio project —
  one control plane, one node pool to manage/patch.
- Simpler networking (no cross-cluster service mesh needed).
- Still gets real isolation via Kubernetes `ResourceQuota`, `NetworkPolicy`,
  and RBAC — namespaces are a legitimate isolation boundary for many
  organizations, not just a toy.

**In favor of separate clusters (the production-grade evolution):**
- True blast-radius isolation: a control-plane-level incident, a
  misconfigured cluster-wide resource (e.g. a bad `ClusterRole` or CRD),
  or a node group exhaustion event in one environment cannot affect
  another.
- Independent Kubernetes version upgrade cadence — you can upgrade dev's
  control plane a week before prod's.
- Required by some compliance regimes that mandate physical/logical
  separation between prod and non-prod.

**How to evolve this repo to separate clusters** if you want to extend it:
`terraform/eks.tf` and `terraform/vpc.tf` become modules invoked three
times with distinct `cluster_name`/`vpc_cidr` values; each
`argocd/apps/app-{env}.yaml` gets a `destination.server` pointing at that
environment's cluster's API endpoint (registered with ArgoCD via
`argocd cluster add`) instead of `https://kubernetes.default.svc`; the
`AppProject`'s `destinations` list is updated accordingly. No change is
needed to `k8s/base/` or the CI/promotion workflows — this is precisely
the point of keeping environment-specific concerns isolated to overlays
and Application manifests.

---

## 8. Why is `FAILURE_RATE` baked into the demo app?

`app/src/index.js` supports an env var that makes the app deliberately
return HTTP 500s at a configurable rate. This isn't a hack left in by
accident — it's how you *demonstrate* the automated-analysis/rollback
behavior without needing a real bug. Set
`FAILURE_RATE=0.5` in an overlay's ConfigMap, promote it, and watch
`k8s/base/analysis-template.yaml`'s Prometheus query cross its
`failureCondition` threshold and Argo Rollouts abort the canary on its
own. This is the single most convincing thing to show in a demo/interview
— it proves the safety net actually functions, rather than just existing
on paper.

---

## 9. Rollback strategy

Two layers, and the doc call-out in the README points here on purpose,
because conflating them is a common mistake:

1. **Rollout-level rollback** (`kubectl argo rollouts undo`) — reverts the
   live traffic to the previous ReplicaSet in seconds. Fast, but it only
   fixes the *cluster*. Git (and thus what ArgoCD believes is "desired
   state") still points at the bad tag.
2. **Git-level rollback** (`git revert` on the promotion commit) — fixes
   the *source of truth*. This is required, or ArgoCD's `selfHeal` will
   eventually notice the cluster doesn't match the (still-bad) desired
   state in git and "helpfully" redeploy the bad version again.

`scripts/rollback.sh` performs step 1 and prints a reminder for step 2 —
deliberately not automated, since reverting a merged PR is itself a
change that arguably deserves the same review it took to get in.

---

## 10. What's intentionally left out (and why)

To keep this a buildable, understandable reference project rather than an
enterprise platform, the following are out of scope, with a one-line note
on what you'd add for a real production system:

- **Secrets management** — real deployments should use External Secrets
  Operator + AWS Secrets Manager/Vault rather than plain ConfigMaps for
  anything sensitive; this demo app has no secrets to manage.
- **Ingress/TLS** — no Ingress controller or cert-manager is wired up; the
  Service is `ClusterIP` only. Add an ALB Ingress Controller + Route53 +
  ACM for real external access.
- **Network policy** — namespaces provide RBAC/quota isolation but not
  network isolation by default; add `NetworkPolicy` resources per
  namespace for real defense-in-depth.
- **Multi-cluster** — see section 7 above.
- **SLO-based alerting on-call integration** — kube-prometheus-stack is
  installed and Grafana is available, but no Alertmanager routes to
  PagerDuty/Opsgenie are configured.

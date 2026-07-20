# Installs ArgoCD itself via the official Helm chart, and namespaces for
# each environment. This is the ONE piece of the platform that is NOT
# managed by GitOps (chicken-and-egg problem: something has to install
# ArgoCD before ArgoCD can manage anything). Everything after this point
# -- the app-of-apps root Application -- is applied once
# (see scripts/bootstrap.sh) and GitOps takes over from there.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.3.11"
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    server = {
      extraArgs = ["--insecure"] # demo only: TLS terminated at an ALB/ingress in real prod
    }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.34.5"
  namespace        = "argo-rollouts"
  create_namespace = true

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.2.1"
  namespace        = "monitoring"
  create_namespace = true

  # Minimal footprint for a demo cluster.
  values = [yamlencode({
    grafana = { enabled = true }
    prometheus = {
      prometheusSpec = {
        retention = "3d"
      }
    }
  })]

  depends_on = [module.eks]
}

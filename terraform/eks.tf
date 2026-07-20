module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true # demo convenience; restrict to VPN/office CIDR in real prod

  # IAM Roles for Service Accounts (IRSA) -- lets pods (e.g. the
  # AWS Load Balancer Controller, External Secrets Operator, Cluster
  # Autoscaler) assume narrowly-scoped IAM roles instead of using node
  # instance-profile credentials.
  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      capacity_type  = "ON_DEMAND"

      labels = {
        role = "general"
      }
    }
  }

  # Map the CI/CD role and any human admins into the aws-auth ConfigMap so
  # both GitHub Actions (for one-off bootstrap tasks) and engineers can
  # `kubectl` against the cluster. ArgoCD itself runs in-cluster and
  # doesn't need an entry here.
  access_entries = {
    ci_role = {
      principal_arn = var.ci_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = {
    Project   = var.cluster_name
    ManagedBy = "terraform"
  }
}

variable "ci_role_arn" {
  description = "IAM role ARN assumed by CI (via OIDC) for cluster bootstrap actions"
  type        = string
}

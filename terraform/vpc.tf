# Single VPC shared by all three namespaces (dev/staging/prod live in one
# cluster in this reference implementation -- see docs/EXPLANATIONS.md for
# the "namespaces vs. separate clusters" trade-off and how to switch to a
# true multi-cluster layout by re-using this module three times with
# distinct CIDRs).

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 3)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # cost optimization for a demo; use one-per-AZ in real prod
  enable_dns_hostnames = true

  # Required tags for the AWS Load Balancer Controller / EKS to discover
  # subnets for public/internal ALBs and auto-scaling.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/${var.cluster_name}"  = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"            = "1"
    "kubernetes.io/cluster/${var.cluster_name}"  = "shared"
  }
}

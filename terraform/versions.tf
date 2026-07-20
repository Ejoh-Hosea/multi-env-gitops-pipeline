terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }

  # Remote state with locking. Create the bucket/table once, out of band,
  # before running `terraform init` (see README bootstrap section).
  backend "s3" {
    bucket         = "REPLACE-ME-gitops-demo-tfstate"
    key            = "gitops-multi-env-pipeline/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE-ME-gitops-demo-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# (helm provider requirement, appended separately to keep versions.tf's
# main required_providers block readable above)

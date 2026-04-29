terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key     = "35-alb-controller/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    helm       = { source = "hashicorp/helm", version = "~> 3.1" }
    tls        = { source = "hashicorp/tls", version = "~> 4.1" }
  }
}

provider "aws" { region = "us-east-1" }

variable "tfstate_bucket" { type = string }
variable "cluster_name" {
  type    = string
  default = "lab"
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "10-network/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "20-eks/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  effective_cluster_name = coalesce(var.cluster_name, data.terraform_remote_state.eks.outputs.cluster_name)
}

data "aws_eks_cluster" "this" {
  name = local.effective_cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = local.effective_cluster_name
}

data "tls_certificate" "oidc" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

module "alb_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name = "aws-load-balancer-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = [
        "kube-system:aws-load-balancer-controller"
      ]
    }
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_ca)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  values = [
    yamlencode({
      clusterName  = local.effective_cluster_name
      region       = "us-east-1"
      vpcId        = data.terraform_remote_state.network.outputs.vpc_id
      replicaCount = 1
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.alb_controller_irsa_role.iam_role_arn
        }
      }
    })
  ]
}

output "alb_controller_role_arn" {
  value = module.alb_controller_irsa_role.iam_role_arn
}

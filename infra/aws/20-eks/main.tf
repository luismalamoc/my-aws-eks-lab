terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key     = "20-eks/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "10-network/terraform.tfstate"
    region = "us-east-1"
  }
}

variable "tfstate_bucket" { type = string }

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.18"

  name               = "lab"
  kubernetes_version = "1.35"

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa = false # usamos Pod Identity

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnets

  addons = {
    # before_compute = true: instalar antes del node group para que los nodos
    # tengan CNI y kube-proxy disponibles al joinear (sin esto, fallan con
    # NodeCreationFailure porque no pueden asignar IP a los system pods).
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      before_compute = true
      most_recent    = true
    }
    # t3.micro tiene presupuesto de pods/IPs muy bajo; forzamos CoreDNS a 1 réplica
    # para evitar Pending con "Too many pods" en lab single-node.
    coredns = {
      configuration_values = jsonencode({
        replicaCount = 1
      })
    }
    eks-pod-identity-agent = {}
    # En t3.micro el presupuesto de pods/IPs por nodo es bajo; dejamos metrics-server
    # fuera por default para mantener el lab estable.
    # metrics-server         = {}
    # aws-ebs-csi-driver omitido: no lo necesitamos para hello-world (sin PVCs)
    # y con desired_size=1 sus 2 réplicas HA se quedan Pending por anti-affinity.
    # Si en el futuro agregás PVCs/StatefulSets, descomentá con replicaCount=1:
    #   aws-ebs-csi-driver = {
    #     configuration_values = jsonencode({ controller = { replicaCount = 1 } })
    #   }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "BOTTLEROCKET_x86_64" # amd64 para compatibilidad production-like
      instance_types = ["t3.micro"]          # Free Tier estricto en 2026
      min_size       = 3
      max_size       = 3
      desired_size   = 3 # fijo en 3 para evitar "Too many pods" con addons base + ALB
    }
  }

  # Access entries: declara explícitamente qué IAM principals son admin del cluster.
  # Sin esto, ni siquiera quien crea el cluster tiene acceso vía kubectl.
  # Usamos el ARN del caller actual (var.cluster_admin_arn opcional para overrides).
  access_entries = {
    creator = {
      principal_arn = coalesce(var.cluster_admin_arn, data.aws_caller_identity.me.arn)
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

data "aws_caller_identity" "me" {}

variable "cluster_admin_arn" {
  description = "IAM principal ARN that gets cluster admin (defaults to caller). Útil cuando aplicas con un role de CI pero quieres dar admin a tu usuario."
  type        = string
  default     = null
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_ca" { value = module.eks.cluster_certificate_authority_data }
output "node_security_group_id" { value = module.eks.node_security_group_id }
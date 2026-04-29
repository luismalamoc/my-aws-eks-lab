terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key          = "25-ecr/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

resource "aws_ecr_repository" "hello_api" {
  name                 = "hello-api"
  image_tag_mutability = "MUTABLE" # facilita iterar; en prod usar IMMUTABLE

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Política de lifecycle: borrar imágenes sin tag después de 1 día,
# y mantener solo las últimas 10 con tag.
resource "aws_ecr_lifecycle_policy" "hello_api" {
  repository = aws_ecr_repository.hello_api.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_url" { value = aws_ecr_repository.hello_api.repository_url }

# my-aws-eks-lab

Learning project: a Python FastAPI "hello world" API that grows from a local Colima/minikube cluster to **AWS EKS**, using the same Helm chart across environments.

## What You Will Build

- A containerized FastAPI service with `/`, `/healthz`, and `/readyz`.
- A reusable Helm chart for local Minikube and EKS deployments.
- AWS infrastructure in Terraform phases (bootstrap, network, EKS, ECR, IAM, ALB controller).
- Public HTTP exposure through Kubernetes Ingress + AWS ALB.

## Project Structure

```text
my-aws-eks-lab/
├── README.md
├── ROADMAP_ES.md
├── ROADMAP_EN.md
├── app/              # FastAPI app + Dockerfile + tests
├── charts/           # Helm chart for hello-api
├── infra/aws/        # Terraform stacks
└── scripts/          # Utility scripts (including teardown)
```

## Step-by-Step Guide

Implementation guides are documented in:

- Spanish: [ROADMAP_ES.md](./ROADMAP_ES.md)
- English: [ROADMAP_EN.md](./ROADMAP_EN.md)

## Prerequisites

- macOS + Homebrew
- Docker runtime (Colima recommended)
- Docker Buildx
- kubectl + Helm + minikube
- AWS CLI v2
- Terraform >= 1.6

## Quick Start

1. Build and test the app locally from `app/`.
2. Create AWS infrastructure with Terraform stacks under `infra/aws/`.
3. Push the app image to ECR.
4. Deploy `hello-api` with Helm using `charts/hello-api/values-eks.yaml`.
5. Validate with:
   - `curl http://<alb-dns>/healthz`
   - `curl http://<alb-dns>/`

## Cost Notes

- EKS control plane has a fixed hourly cost.
- NAT Gateway and ALB are typically the biggest additional costs.
- Use the teardown flow when not actively practicing to keep spend low.

## Cleanup

Use the teardown helper:

```bash
AWS_PROFILE=personal ./scripts/teardown.sh
```

## License

[MIT](./LICENSE)

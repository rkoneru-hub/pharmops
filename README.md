# PharmOps

Pharmaceutical platform with 5 microservices deployed on AWS EKS using GitOps.

## Repositories

| Repo | Purpose |
|------|---------|
| [`pharmops`](https://github.com/ravdy/pharmops) | Terraform — AWS infrastructure (this repo) |
| [`pharmops-gitops`](https://github.com/ravdy/pharmops-gitops) | Helm charts, ArgoCD apps, K8s manifests, DB init |

## Architecture

- **Frontend:** React + Nginx (`pharma-ui`)
- **API Gateway:** Spring Boot — routes and validates JWT
- **Auth:** Spring Boot — login, JWT issuance
- **Catalog:** Spring Boot — drug/dosage CRUD
- **Notifications:** Node.js — async email alerts
- **Database:** PostgreSQL on AWS RDS (schema-per-service)
- **Infrastructure:** Terraform on AWS EKS
- **GitOps:** ArgoCD watching `pharmops-gitops`

## Repository Structure

```
pharmops/
├── pharma-devops/
│   ├── terraform/             # AWS infrastructure (VPC, EKS, RDS, ECR, IAM)
│   │   ├── modules/           # Reusable modules: vpc, eks, rds, ecr, iam, secrets-manager
│   │   └── envs/              # Per-environment configs: dev, qa, prod
│   └── .github/workflows/     # GitHub Actions CI pipelines
├── services/                  # Microservice source code
│   ├── pharma-ui/             # React frontend
│   ├── api-gateway/           # Spring Boot gateway
│   ├── auth-service/          # Spring Boot JWT auth
│   ├── catalog-service/       # Spring Boot drug catalog
│   └── notification-service/  # Node.js notifications
├── PLATFORM_BOOTSTRAP.md      # Full setup guide
└── README.md
```

## Services

| Service | Stack | Port | Description |
|---------|-------|------|-------------|
| `pharma-ui` | React + Nginx | 80 | Frontend |
| `api-gateway` | Spring Boot | 8080 | Entry point + JWT routing |
| `auth-service` | Spring Boot | 8081 | Authentication + JWT |
| `catalog-service` | Spring Boot | 8082 | Drug management CRUD |
| `notification-service` | Node.js | 3000 | Email/SMS alerts |

## Quick Start (Local Development)

```bash
docker-compose up -d
open http://localhost:3001
# Default credentials: admin / admin123
```

## Deploy to AWS EKS

See [PLATFORM_BOOTSTRAP.md](PLATFORM_BOOTSTRAP.md) for the full step-by-step guide.

**Summary:**

```bash
# 1. Provision AWS infrastructure (this repo)
cd pharma-devops/terraform/envs/dev
terraform init && terraform apply

# 2. Install cluster add-ons + ArgoCD (pharmops-gitops repo)
cd pharmops-gitops
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f argocd/install/argocd-namespace.yaml

# 3. Apply ArgoCD project and per-service applications
kubectl apply -f argocd/projects/pharma-project.yaml
kubectl apply -f argocd/apps/dev/pharma-ui/application.yaml
kubectl apply -f argocd/apps/dev/api-gateway/application.yaml
kubectl apply -f argocd/apps/dev/auth-service/application.yaml
kubectl apply -f argocd/apps/dev/notification-service/application.yaml
kubectl apply -f argocd/apps/dev/catalog-service/application.yaml
```

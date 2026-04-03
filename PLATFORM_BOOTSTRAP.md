# PharmOps — Platform Bootstrap Guide

> **Goal:** Get all 5 microservices running on EKS via ArgoCD.
> CI/CD (GitHub Actions) comes in Phase 2. Monitoring comes in Phase 3.

---

## Two Repositories — Clear Responsibilities

| Repo | URL | Contains |
|------|-----|----------|
| `pharmops` | `https://github.com/ravdy/pharmops` | Terraform — AWS infrastructure only |
| `pharmops-gitops` | `https://github.com/ravdy/pharmops-gitops` | Helm charts, ArgoCD apps, K8s manifests, DB init |

Clone both before starting:

```bash
git clone https://github.com/ravdy/pharmops.git
git clone https://github.com/ravdy/pharmops-gitops.git
```

---

## Bootstrap Overview

```
Step 1  → Terraform: VPC + ECR + EKS + RDS         (pharmops repo)
Step 2  → Connect kubectl to the new EKS cluster
Step 3  → Install cluster add-ons + ArgoCD          (pharmops-gitops repo)
Step 4  → Initialize database schemas
Step 5  → Build Docker images and push to ECR       (pharmops repo)
Step 6  → Update image tags in GitOps repo          (pharmops-gitops repo)
Step 7  → Apply ArgoCD project and applications     (pharmops-gitops repo)
Step 8  → Verify everything is running
```

---

## Services

| Service | Stack | Port | Deployed via |
|---------|-------|------|--------------|
| `pharma-ui` | React + Nginx | 80 | Raw K8s manifests |
| `api-gateway` | Spring Boot | 8080 | Helm chart |
| `auth-service` | Spring Boot | 8081 | Helm chart |
| `catalog-service` | Spring Boot | 8082 | Helm chart |
| `notification-service` | Node.js | 3000 | Helm chart |

> **Note:** `pharma-ui` is intentionally deployed via raw Kubernetes manifests (not Helm)
> to demonstrate the difference — all other services use the shared Helm chart.

---

## Step 1 — Terraform: Create All Infrastructure

### 1.1 Bootstrap Remote State (One-Time)

```bash
# Create S3 bucket for Terraform state
aws s3api create-bucket --bucket pharma-tf-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket pharma-tf-state \
  --versioning-configuration Status=Enabled

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name pharma-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.2 Apply Terraform

```bash
cd pharmops/pharma-devops/terraform/envs/dev

cat > terraform.tfvars << 'EOF'
db_password = "PharmaSecure#2024Dev!"
jwt_secret  = "pharma-jwt-super-secret-dev-key-min-32-chars"
EOF

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**What gets created:**

| Resource | Details |
|----------|---------|
| VPC | 10.0.0.0/16, 3 subnet tiers |
| EKS Cluster | pharmops-dev, t2.small nodes |
| RDS PostgreSQL | db.t3.micro, pharmadb |
| ECR Repositories | 5 repos (one per service) |
| IAM Roles | ESO role, node role |
| Secrets Manager | dev/pharma/db, dev/pharma/jwt |

> **Teaching point:** One `terraform apply` creates ~30 AWS resources in the right order.
> This is IaC — repeatable, version-controlled, reviewable infrastructure.

---

## Step 2 — Connect kubectl

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name pharmops-dev \
  --alias pharmops-dev

# Verify — nodes should be in Ready state
kubectl get nodes
kubectl get nodes -o wide
```

---

## Step 3 — Install Cluster Add-ons

All K8s and ArgoCD manifests live in `pharmops-gitops`. Run from inside that repo:

```bash
cd pharmops-gitops

# Add Helm repos
helm repo add ingress-nginx    https://kubernetes.github.io/ingress-nginx
helm repo add external-secrets https://charts.external-secrets.io
helm repo add argo             https://argoproj.github.io/argo-helm
helm repo update

# Create namespaces
kubectl apply -f k8s/namespaces.yaml

# Install NGINX Ingress Controller
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values k8s/ingress/nginx-values.yaml --wait

# Install External Secrets Operator
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace kube-system \
  --set installCRDs=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/pharmops-dev-eso-role" \
  --wait

# Wait for CRDs to be fully registered in the API server before applying ClusterSecretStore
# --wait on helm only waits for pods — CRDs need a few extra seconds to propagate
kubectl wait --for condition=established \
  crd/clustersecretstores.external-secrets.io \
  --timeout=60s

# Clear kubectl's local discovery cache — it may still serve a stale API list
# that doesn't include the newly installed CRDs, causing "no matches for kind" errors
rm -rf ~/.kube/cache/discovery

# Confirm CRD is visible before applying (optional sanity check)
kubectl api-resources | grep clustersecretstore

# Apply ExternalSecrets (pulls secrets from AWS Secrets Manager into K8s)
kubectl apply -f k8s/external-secrets/cluster-secret-store.yaml
kubectl apply -f k8s/external-secrets/dev-external-secrets.yaml

# Install ArgoCD
kubectl apply -f argocd/install/argocd-namespace.yaml
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --wait
```

Verify ArgoCD is up:
```bash
kubectl get pods -n argocd
```

Get ArgoCD admin password:
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
```

---

## Step 4 — Initialize Database Schemas

```bash
# Run from pharmops repo — needs terraform output
cd pharmops/pharma-devops/terraform/envs/dev
export RDS_ENDPOINT=$(terraform output -raw rds_endpoint)

kubectl run psql-init --rm -it \
  --image=postgres:15-alpine \
  --namespace=dev \
  --env="PGPASSWORD=PharmaSecure#2024Dev!" \
  -- psql -h ${RDS_ENDPOINT} -U pharmaadmin -d pharmadb \
  -c "
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS catalog;
GRANT ALL ON SCHEMA auth, catalog TO pharmaadmin;
SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%';
"
```

---

## Step 5 — Build Docker Images and Push to ECR

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${REGISTRY}
```

Create `build-all.sh` in the `pharmops` root:

```bash
#!/bin/bash
set -e

TAG="v1.0.0"
SERVICES=(
  auth-service
  api-gateway
  catalog-service
  notification-service
  pharma-ui
)

for svc in "${SERVICES[@]}"; do
  echo "========== Building: $svc =========="
  docker build -t "${REGISTRY}/${svc}:${TAG}" "services/${svc}"
  docker push "${REGISTRY}/${svc}:${TAG}"
  echo "Pushed: ${REGISTRY}/${svc}:${TAG}"
done

echo "All 5 images pushed to ECR successfully!"
```

```bash
chmod +x build-all.sh && ./build-all.sh
```

---

## Step 6 — Update Image Tags in GitOps Repo

```bash
cd pharmops-gitops

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
```

**Helm-managed services** — update values files:

```bash
for svc in auth-service api-gateway catalog-service notification-service; do
  FILE="envs/dev/values-${svc}.yaml"
  sed -i "s|repository:.*|repository: ${REGISTRY}/${svc}|" "$FILE"
  sed -i "s|tag:.*|tag: v1.0.0|" "$FILE"
done
```

**pharma-ui** — update the raw manifest directly (no values file):

```bash
sed -i "s|image:.*|image: ${REGISTRY}/pharma-ui:v1.0.0|" \
  k8s-manifests/pharma-ui/deployment.yaml
```

> **Teaching point:** This is one of the pain points of raw manifests — you have to
> manually find and edit the image line in the deployment file. With Helm, it's always
> `tag:` in one values file across all environments.

```bash
git add . && git commit -m "Set ECR image tags v1.0.0 for dev" && git push
```

---

## Step 7 — Apply ArgoCD Project and Applications

```bash
cd pharmops-gitops

# Apply the ArgoCD project first
kubectl apply -f argocd/projects/pharma-project.yaml

# Apply RBAC
kubectl apply -f k8s/rbac/cluster-roles.yaml
kubectl apply -f k8s/rbac/dev-role.yaml
kubectl apply -f k8s/rbac/rolebindings.yaml

# Apply individual Application manifests — one per service
kubectl apply -f argocd/apps/dev/pharma-ui/application.yaml
kubectl apply -f argocd/apps/dev/api-gateway/application.yaml
kubectl apply -f argocd/apps/dev/auth-service/application.yaml
kubectl apply -f argocd/apps/dev/notification-service/application.yaml
kubectl apply -f argocd/apps/dev/catalog-service/application.yaml
```

### How each Application is configured

**pharma-ui** — points to raw K8s manifests:
```yaml
source:
  repoURL: https://github.com/ravdy/pharmops-gitops.git
  path: k8s-manifests/pharma-ui     # plain YAML — no Helm block
```

**All other services** — points to shared Helm chart with service-specific values:
```yaml
source:
  repoURL: https://github.com/ravdy/pharmops-gitops.git
  path: pharma-service               # shared Helm chart
  helm:
    valueFiles:
      - ../envs/dev/values-auth-service.yaml
```

### Port-forward ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080
# Username: admin  |  Password: (from Step 3)
```

In the ArgoCD UI you will see 5 separate applications:

| App name | Deployed via |
|---|---|
| `pharma-ui-dev` | Raw K8s manifests |
| `api-gateway-dev` | Helm |
| `auth-service-dev` | Helm |
| `notification-service-dev` | Helm |
| `catalog-service-dev` | Helm |

Sync all from terminal:

```bash
argocd app sync pharma-ui-dev api-gateway-dev auth-service-dev notification-service-dev catalog-service-dev

# Watch pods come up
kubectl get pods -n dev -w
```

---

## Step 8 — Verify

```bash
# All 5 pods should be Running
kubectl get pods -n dev
kubectl get svc -n dev

# Test pharma-ui
kubectl port-forward svc/pharma-ui -n dev 8090:80 &
curl http://localhost:8090
# Returns HTML

# Test auth service
kubectl port-forward svc/auth-service -n dev 8081:8081 &
curl http://localhost:8081/actuator/health
# {"status":"UP"}

curl -X POST http://localhost:8081/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@pharma.com","password":"Admin@123"}'
# Returns JWT token

# Test catalog service
kubectl port-forward svc/catalog-service -n dev 8082:8082 &
curl http://localhost:8082/actuator/health
# {"status":"UP"}
```

---

## Bootstrap Complete

What students can now observe:

- 5 microservices running on Kubernetes across two deployment strategies
- `pharma-ui` deployed via raw manifests — hardcoded values, manual image updates
- 4 services deployed via Helm — one chart, one values file per service
- ArgoCD managing each service independently with separate sync/rollback
- Secrets pulled from AWS Secrets Manager via External Secrets Operator
- NGINX Ingress routing external traffic into the cluster

**Next phases:**
- Phase 2: GitHub Actions CI/CD — automate the manual docker build + push + image tag update
- Phase 3: Monitoring with Prometheus + Grafana

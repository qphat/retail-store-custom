# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

AWS Containers Retail Store sample app — polyglot microservices demo for learning DevOps. Nx monorepo with Yarn 4 (Corepack). All services under `src/`.

## Toolchain Setup

```bash
mise install   # Java 21, Node 22, Go 1.25, Maven 3.9
yarn install   # Nx + root deps
```

## Build & Test

```bash
yarn nx build <service>
yarn nx test <service>
yarn nx test:integration <service>
yarn nx lint <service>
yarn nx serve <service>           # runs on port 8080
yarn nx run-many -t build --projects=tag:service
```

### Per-language notes

- **catalog** (Go): `go build -o dist/main main.go` / `go test -v ./test/...`
- **cart, orders, ui** (Java/Spring Boot): Maven wrapper `./mvnw`; unit tests exclude `integration` group; cart integration tests need dummy AWS creds
- **checkout** (Node/NestJS): `yarn install` inside `src/checkout/` first; Yarn 4 Berry — binary at `.yarn/releases/`
- **lint** for Java: `./mvnw checkstyle:checkstyle`

## Service Architecture

All services expose port 8080, instrumented with Prometheus metrics and OpenTelemetry tracing.

| Service | Language | Persistence | Key env vars |
|---|---|---|---|
| `ui` | Java + Spring Boot | Gateway | `RETAIL_UI_ENDPOINTS_*` |
| `catalog` | Go + Gin | MySQL or in-memory | `RETAIL_CATALOG_PERSISTENCE_*` |
| `cart` | Java + Spring Boot | DynamoDB or in-memory | `RETAIL_CART_PERSISTENCE_*` |
| `orders` | Java + Spring Boot | PostgreSQL + RabbitMQ or in-memory | `RETAIL_ORDERS_PERSISTENCE_*`, `RETAIL_ORDERS_MESSAGING_*` |
| `checkout` | Node + NestJS | Redis or in-memory | `RETAIL_CHECKOUT_PERSISTENCE_*`, `RETAIL_CHECKOUT_ENDPOINTS_ORDERS` |

Default persistence provider is `in-memory` for all services — no external deps needed for local dev.

## Docker

Each service has a multi-stage Dockerfile. Run the full stack:

```bash
cd src/ui
docker compose up --build    # all 5 services + observability stack
```

Individual service compose files at `src/<service>/docker-compose.yml`.

### Ports

| Service | Port |
|---|---|
| ui | 8888 |
| catalog | 8081 |
| cart | 8082 |
| orders | 8083 |
| checkout | 8084 |
| Prometheus | 9090 |
| Grafana | 3000 (admin/admin) |
| Kibana | 5601 |

## Observability (src/ui/observability/)

- `prometheus.yml` — scrape config for all 5 services
- `grafana/datasources.yml` — Prometheus datasource with pinned UID `PBFA97CFB590B2093`
- `grafana/dashboards/` — JVM and Go dashboards provisioned as code
- `filebeat/filebeat.yml` — ships container logs to Elasticsearch

Kibana data view (`.ds-logs-*`) is auto-created by `kibana-setup` container in docker-compose.

## CI/CD (.github/workflows/)

Four workflows:

### cicd.yml — Build + Deploy to ECS (main branch)
- `detect-changes` → matrix build per changed service
- Build → Trivy scan (CRITICAL CVEs) → Push :{sha} + :latest → Deploy to ECS
- Deploy: download task def → render :{sha} image → register new revision → update service → wait stable → HTTP health check
- `smoke-test` job: verifies all 5 services + Kibana through ALB after deploy
- OIDC auth (no long-lived AWS keys), concurrency guard per service, 3-attempt retry

### eks-deploy.yml — Build + Deploy to EKS (feat/eks branch)
- Same detect-changes → build → Trivy scan → push logic as cicd.yml
- Deploy: `aws eks update-kubeconfig` → `helm upgrade --install ingress-nginx` → `helm upgrade --install retail-store` with `--set imageTag={sha}`
- Smoke test via NGINX ingress hostname after deploy
- Concurrency guard, OIDC auth

### terraform.yml — Terraform CI/CD
- PR: detect changed envs → lint (fmt+validate) → security scan (tfsec+checkov) → plan per env → PR comment
- Push to main: `apply-dev` auto, `apply-staging/prod` via workflow_dispatch + GitHub Environment approval
- Concurrency guard per env, plugin cache, `-lock-timeout=5m`

### terraform-drift.yml — Drift Detection
- Runs 13:00 Vietnam time (06:00 UTC) weekdays + manual dispatch
- `terraform plan -detailed-exitcode -lock=false` per env
- Exit 2 = drift → opens/updates GitHub Issue with labels `terraform-drift` + env

Required GitHub **secrets**: `DOCKER_USERNAME`, `DOCKER_PASSWORD`
Required GitHub **variables**: `DOCKER_REGISTRY` (`docker.io`), `IMAGE_PREFIX` (`koomi1/retail-app`), `AWS_ROLE_ARN`, `AWS_REGION` (`us-east-1`)

## Kubernetes (k8s/)

Raw manifests for learning — one Deployment + Service per service.

```bash
kubectl apply -f k8s/catalog/
kubectl apply -f k8s/          # all services
kubectl delete -f k8s/
kubectl port-forward svc/ui 8080:80
```

- All services use `in-memory` persistence — no external deps
- Ingress at `k8s/ingress.yaml` routes `/` → ui Service
- Kind cluster: `kind create cluster --name retail --config kind-config.yaml`
- nginx ingress: `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml`
- Docker Hub: `koomi1/retail-app-<service>:latest`

## Helm (helm/retail-store/)

One chart for all 5 services + full observability stack (Prometheus, Grafana, ELK, Filebeat).
Templates loop over `values.yaml` services map.

```bash
helm template retail-store helm/retail-store   # render without deploying
helm install retail-store helm/retail-store
helm upgrade retail-store helm/retail-store --set imageTag=<sha>
helm uninstall retail-store
helm list
```

- `Chart.yaml` — chart metadata
- `values.yaml` — image registry, tag, per-service env vars, resources, IRSA annotations
- `templates/deployment.yaml` — loops `range .Values.services`
- `templates/service.yaml` — loops `range .Values.services`
- `templates/serviceaccount.yaml` — creates ServiceAccounts with IRSA annotations (EKS only)
- `templates/ingress.yaml` — conditional on `ingress.enabled`
- `templates/monitoring/` — Prometheus + Grafana deployments + configmaps
- `templates/logging/` — Elasticsearch, Kibana, Filebeat DaemonSet

## Terraform (terraform/)

Two deployment targets: ECS Fargate (`main` branch) and EKS (`feat/eks` branch).

```bash
# One-time backend setup
bash terraform/scripts/setup-backend.sh

# One-time OIDC setup (GitHub Actions auth)
cd terraform/global && terraform init && terraform apply

# ECS environments (dev/staging/prod)
cd terraform/environments/dev
terraform init -reconfigure && terraform plan && terraform apply

# EKS environment (feat/eks branch)
cd terraform/environments/eks-dev
terraform init && terraform plan && terraform apply
# After apply: aws eks update-kubeconfig --name eks-dev-retail-store --region us-east-1
```

### Module layout

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, public/private subnets, IGW, NAT gateway |
| `modules/ecs-cluster` | ECS cluster + CloudWatch log group |
| `modules/alb` | ALB, security group, HTTP listener |
| `modules/ecs-service` | Task def (app + FireLens sidecar), ECS service, Cloud Map, ALB rule, IAM roles |
| `modules/logging` | Elasticsearch + Kibana ECS services, Cloud Map namespace, SSM Fluent Bit config |
| `modules/eks-cluster` | EKS control plane, managed node group, OIDC provider, IRSA roles |
| `global/` | GitHub OIDC provider + IAM role for CI/CD |

### Environments

| Environment | Path | Target | Branch |
|---|---|---|---|
| `dev` | `environments/dev/` | ECS Fargate | `main` |
| `staging` | `environments/staging/` | ECS Fargate | `main` |
| `prod` | `environments/prod/` | ECS Fargate | `main` |
| `eks-dev` | `environments/eks-dev/` | EKS (t3.medium x2) | `feat/eks` |

### ECS key design decisions
- **FireLens sidecar** per task (Fluent Bit) — ships logs to Elasticsearch
- **Cloud Map** (`{env}.local`) — service discovery DNS
- **in-memory persistence** for all app services in dev
- **Fargate valid CPU/memory combos**: 256/512, 512/1024+, 1024/2048+, 2048/4096+

### EKS key design decisions
- **NGINX ingress controller** — provisions NLB in public subnets, routes to pods
- **IRSA** (IAM Roles for Service Accounts) — pod-level AWS auth; replaces ECS task roles
- **CoreDNS** — service discovery (`{service}.default.svc.cluster.local`); replaces Cloud Map
- **Filebeat DaemonSet** — log collection; replaces FireLens sidecar per task
- **Subnet tagging** — required for EKS to discover subnets for LB provisioning
- VPC CIDR `10.1.0.0/16` — separate from ECS dev (`10.0.0.0/16`)

### Remote state
- Bucket: `retail-store-tf-state-{account_id}`
- Keys: `retail-store/{env}/terraform.tfstate`, `retail-store/global/terraform.tfstate`

## Key Files

- `DEVOPS_NOTES.md` — Docker/CI implementation notes and interview Q&A
- `K8S_HELM_NOTES.md` — Kubernetes and Helm learning notes and interview Q&A
- `TERRAFORM_NOTES.md` — Terraform + ECS Fargate learning notes and interview Q&A
- `CICD_ECS_NOTES.md` — CI/CD pipeline architecture, implementation guide, interview Q&A
- `docs/containers-and-databases.md` — DB patterns, migrations, secrets, interview Q&A
- `docs/interview-strategy.md` — Full interview prep: technical Q&A, culture, DevSecOps, architecture cheat sheets
- `src/ui/README.md` — UI service docs with all env vars and endpoints

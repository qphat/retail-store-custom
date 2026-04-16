# EKS & CI/CD — Learning Notes & Interview Q&A

> Based on the retail-store-sample-app EKS deployment (`feat/eks` branch).
> Covers: what EKS is, how it compares to ECS, how we implemented it,
> CI/CD with GitHub Actions + Helm, and interview Q&A.

---

## Table of Contents

1. [What is EKS?](#1-what-is-eks)
2. [EKS vs ECS vs Self-Managed K8s](#2-eks-vs-ecs-vs-self-managed-k8s)
3. [EKS Architecture Deep Dive](#3-eks-architecture-deep-dive)
4. [How We Built It — Terraform Module](#4-how-we-built-it--terraform-module)
5. [IRSA — IAM Roles for Service Accounts](#5-irsa--iam-roles-for-service-accounts)
6. [NGINX Ingress Controller](#6-nginx-ingress-controller)
7. [Helm Deployment](#7-helm-deployment)
8. [Service Discovery — CoreDNS vs Cloud Map](#8-service-discovery--coredns-vs-cloud-map)
9. [Logging — Filebeat DaemonSet vs FireLens](#9-logging--filebeat-daemonset-vs-firelens)
10. [CI/CD with GitHub Actions](#10-cicd-with-github-actions)
11. [ECS vs EKS — Side-by-Side Comparison](#11-ecs-vs-eks--side-by-side-comparison)
12. [Common Issues & Fixes](#12-common-issues--fixes)
13. [Interview Q&A](#13-interview-qa)

---

## 1. What is EKS?

**Amazon Elastic Kubernetes Service (EKS)** is AWS's managed Kubernetes service.
It runs the Kubernetes control plane for you — you only manage the worker nodes and workloads.

```
Without EKS (self-managed):
  You manage:  etcd, API server, scheduler, controller manager, upgrades, HA, backups
  You manage:  worker nodes, networking, storage

With EKS:
  AWS manages: control plane (etcd, API server, scheduler, controller manager)
               control plane HA across 3 AZs, automatic upgrades available
  You manage:  worker nodes (EC2 or Fargate), networking add-ons, workloads
```

### What Kubernetes actually does

Kubernetes (K8s) is a **container orchestrator** — it runs your containers across a cluster of machines and handles:

| Problem | K8s solution |
|---|---|
| Container crashes → restart it | Liveness probe + automatic restart |
| Node dies → move containers | Pod rescheduling |
| Traffic → distribute to healthy pods | Service + readiness probe |
| Deploy new version safely | Rolling update (Deployment) |
| Scale up when load spikes | HorizontalPodAutoscaler |
| Expose app to internet | Ingress + Ingress Controller |
| Store secrets safely | Secret (+ External Secrets Operator) |

---

## 2. EKS vs ECS vs Self-Managed K8s

| | Self-managed K8s | ECS Fargate | EKS |
|---|---|---|---|
| Control plane | You manage | AWS manages | AWS manages |
| Worker nodes | You manage | None (serverless) | You manage (EC2) or Fargate |
| Networking | You choose CNI | AWS VPC | VPC CNI (AWS) |
| Service discovery | CoreDNS | Cloud Map | CoreDNS |
| Load balancing | Any ingress | ALB (via listener rules) | Any ingress (NGINX, AWS LBC) |
| Logging | DaemonSet | FireLens sidecar | DaemonSet |
| IAM auth | Manual | Task role | IRSA |
| Learning curve | Highest | Lowest | Medium |
| Portability | High | Low (AWS-only) | High (K8s API is standard) |
| Cost | EC2 + ops time | Per task-second | $0.10/hr cluster + EC2 |
| Industry adoption | — | AWS teams | Most companies |

### When to choose each

```
ECS Fargate:  Small AWS-native team, want simplicity, no K8s expertise needed
EKS:          Need K8s ecosystem (ArgoCD, Istio, Karpenter), multi-cloud future,
              team already knows K8s, need fine-grained scheduling
Self-managed: Full control needed, on-prem, specific compliance requirements
```

---

## 3. EKS Architecture Deep Dive

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS Account                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              EKS Control Plane (AWS managed)         │   │
│  │                                                      │   │
│  │  API Server ──→ etcd (cluster state)                 │   │
│  │  Scheduler  ──→ assigns pods to nodes                │   │
│  │  Controller ──→ ensures desired state                │   │
│  └─────────────────────┬────────────────────────────────┘   │
│                        │ kubectl / API calls                 │
│  ┌─────────────────────▼────────────────────────────────┐   │
│  │                    VPC (10.1.0.0/16)                 │   │
│  │                                                      │   │
│  │  Public subnets ──→ NGINX NLB (internet-facing)      │   │
│  │                        │                             │   │
│  │  Private subnets ─────▼──────────────────────────    │   │
│  │  ┌──────────────┐  ┌──────────────┐                  │   │
│  │  │  Node 1      │  │  Node 2      │  (t3.medium)     │   │
│  │  │  ┌─────────┐ │  │ ┌─────────┐  │                  │   │
│  │  │  │ catalog │ │  │ │   ui    │  │                  │   │
│  │  │  │   pod   │ │  │ │   pod   │  │                  │   │
│  │  │  └─────────┘ │  │ └─────────┘  │                  │   │
│  │  │  ┌─────────┐ │  │ ┌─────────┐  │                  │   │
│  │  │  │  cart   │ │  │ │ orders  │  │                  │   │
│  │  │  │   pod   │ │  │ │   pod   │  │                  │   │
│  │  │  └─────────┘ │  │ └─────────┘  │                  │   │
│  │  └──────────────┘  └──────────────┘                  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Key EKS components

**Control plane** (AWS managed, you pay $0.10/hr):
- **API server** — accepts `kubectl` commands, stores desired state
- **etcd** — distributed key-value store, holds all cluster state
- **Scheduler** — decides which node each pod runs on
- **Controller manager** — reconciliation loop: if desired ≠ actual → fix it

**Data plane** (you manage):
- **Worker nodes** (EC2) — where your pods actually run
- **kubelet** — agent on each node, talks to API server, starts/stops pods
- **kube-proxy** — handles network rules for Service routing
- **VPC CNI** — AWS CNI plugin, gives each pod a real VPC IP address

**Add-ons** (managed by AWS EKS):
- **CoreDNS** — cluster DNS (`service.namespace.svc.cluster.local`)
- **kube-proxy** — Service IP routing
- **vpc-cni** — pod networking

---

## 4. How We Built It — Terraform Module

### Module structure

```
terraform/modules/eks-cluster/
├── main.tf        # cluster, node group, OIDC, IRSA
├── variables.tf   # env_name, vpc_id, subnet IDs, node sizing
└── outputs.tf     # cluster_name, endpoint, OIDC URL, IRSA role ARNs

terraform/environments/eks-dev/
├── main.tf        # instantiates vpc + eks modules
├── variables.tf   # defaults: t3.medium, 2 nodes, K8s 1.32
├── terraform.tfvars
├── backend.tf     # S3 key: retail-store/eks-dev/terraform.tfstate
├── provider.tf    # aws + tls providers
└── outputs.tf     # kubeconfig_command, cart_irsa_role_arn
```

### What `terraform apply` creates

```
1. VPC (10.1.0.0/16)
   ├── 2 public subnets  (for NLB provisioned by NGINX)
   └── 2 private subnets (for worker nodes)

2. Subnet tags (required for EKS)
   ├── kubernetes.io/cluster/{name} = shared
   ├── kubernetes.io/role/elb = 1        (public  → internet-facing LB)
   └── kubernetes.io/role/internal-elb = 1 (private → internal LB)

3. EKS cluster (control plane)
   ├── IAM role: eks.amazonaws.com → AmazonEKSClusterPolicy
   └── VPC config: private + public subnets, public endpoint enabled

4. EKS add-ons: coredns, kube-proxy, vpc-cni

5. Managed node group
   ├── 2x t3.medium in private subnets
   ├── IAM role: AmazonEKSWorkerNodePolicy + CNI + ECR read
   └── Auto scaling: min=1, desired=2, max=3

6. OIDC provider (for IRSA)
   └── Fetches EKS cluster TLS cert → registers with AWS IAM

7. IRSA role for cart service
   └── Trusts: system:serviceaccount:default:cart
   └── Policy: DynamoDB access to {env}-cart table
```

### Why subnet tagging matters

EKS and the NGINX ingress controller need to discover which subnets to use for load balancers.
They do this by reading subnet tags:

```hcl
# Public subnets → internet-facing NLB (NGINX ingress)
resource "aws_ec2_tag" "public_subnet_elb" {
  key   = "kubernetes.io/role/elb"
  value = "1"
}

# Private subnets → internal LBs
resource "aws_ec2_tag" "private_subnet_elb" {
  key   = "kubernetes.io/role/internal-elb"
  value = "1"
}
```

Without these tags: NGINX ingress controller cannot provision a load balancer → no external access.

### Deploy sequence

```bash
cd terraform/environments/eks-dev
terraform init
terraform apply       # ~15 minutes for EKS cluster

# Configure kubectl
aws eks update-kubeconfig --name eks-dev-retail-store --region us-east-1
kubectl get nodes     # 2 nodes, status Ready

# Deploy NGINX ingress controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# Deploy app
helm upgrade --install retail-store helm/retail-store --wait
kubectl get ingress   # get the NLB hostname
```

---

## 5. IRSA — IAM Roles for Service Accounts

### The problem

In ECS, each task has a **task role** — the container gets AWS credentials automatically.
In Kubernetes, pods don't have IAM roles by default — you'd have to put credentials in a Secret (bad).

### The solution: IRSA

IRSA (IAM Roles for Service Accounts) lets a **Kubernetes ServiceAccount** assume an **IAM role**
via OIDC federation — no credentials stored anywhere.

```
How it works:

1. EKS has an OIDC issuer URL (unique per cluster)
2. AWS IAM trusts that OIDC issuer (we register it as an identity provider)
3. We create an IAM role with a trust policy:
   "Allow system:serviceaccount:default:cart to assume this role"
4. Cart pod's ServiceAccount is annotated with the role ARN
5. AWS SDK in the pod calls EKS token endpoint → gets temporary credentials
6. Pod can now call DynamoDB — no access keys in code or secrets
```

### Implementation

**Terraform — OIDC provider:**
```hcl
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
```

**Terraform — IRSA role for cart:**
```hcl
resource "aws_iam_role" "cart_irsa" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:default:cart"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
```

**Helm — ServiceAccount with annotation:**
```yaml
# helm/retail-store/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cart
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789:role/eks-dev-cart-irsa"
```

**Deploy with annotation:**
```bash
helm upgrade retail-store helm/retail-store \
  --set "services.cart.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<ARN>"
```

### IRSA vs ECS Task Role

| | ECS Task Role | IRSA |
|---|---|---|
| Scope | Per task definition | Per K8s ServiceAccount |
| How it works | ECS injects credentials via metadata endpoint | OIDC token → STS AssumeRoleWithWebIdentity |
| Config location | Task definition JSON | ServiceAccount annotation |
| Rotation | Automatic (ECS manages) | Automatic (STS token TTL) |
| No credentials in code | Yes | Yes |

---

## 6. NGINX Ingress Controller

### What it is

An Ingress Controller watches Kubernetes `Ingress` resources and configures a load balancer accordingly.

```
Internet
    │
    ▼
AWS NLB (created by NGINX ingress controller)
    │
    ▼
NGINX pods (ingress-nginx namespace)
    │  reads Ingress rules
    ├──▶ / → ui Service → ui pods
    ├──▶ /catalogue → catalog Service → catalog pods
    ├──▶ /api/cart → cart Service → cart pods
    └──▶ /kibana → kibana Service → kibana pod
```

### Why NGINX instead of AWS Load Balancer Controller

| | NGINX Ingress | AWS Load Balancer Controller |
|---|---|---|
| Ingress class | `nginx` | `alb` |
| LB type | NLB (Network) | ALB (Application) |
| Our Helm chart expects | `nginx` ← | `alb` (would need changes) |
| Path rewriting | Built-in | Limited |
| Cost | NLB pricing | ALB pricing (slightly more) |

Our Helm chart was written for NGINX ingress — zero changes needed.

### Deploy

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait
```

After deploy, AWS provisions an NLB. Get its hostname:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP = something.elb.us-east-1.amazonaws.com
```

### Ingress resource (from our Helm chart)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: retail-store
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /()(.*)
            pathType: Prefix
            backend:
              service:
                name: ui
                port: { number: 80 }
          - path: /grafana(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: grafana
                port: { number: 3000 }
          - path: /kibana(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: kibana
                port: { number: 5601 }
```

---

## 7. Helm Deployment

### Why Helm instead of raw kubectl apply

| | `kubectl apply -f k8s/` | `helm install` |
|---|---|---|
| Version tracking | No | Yes (`helm list`, `helm history`) |
| Rollback | Manual | `helm rollback retail-store 1` |
| Templating | No | Yes (loop over services, conditionals) |
| One command for all | No (multiple dirs) | Yes |
| Values per env | Hardcoded YAML | `--set` or `-f values-prod.yaml` |
| Upgrade | Re-apply all | `helm upgrade` (diff + apply) |

### Our chart structure

```
helm/retail-store/
├── Chart.yaml                          # name, version, appVersion
├── values.yaml                         # defaults for all services
└── templates/
    ├── deployment.yaml                 # range .Values.services → 5 Deployments
    ├── service.yaml                    # range .Values.services → 5 Services
    ├── serviceaccount.yaml             # per-service ServiceAccounts (IRSA)
    ├── ingress.yaml                    # 1 Ingress with all path rules
    ├── monitoring/
    │   ├── prometheus-deployment.yaml
    │   ├── prometheus-configmap.yaml
    │   ├── prometheus-service.yaml
    │   ├── grafana-deployment.yaml
    │   ├── grafana-configmap.yaml
    │   ├── grafana-dashboards-configmap.yaml
    │   └── grafana-service.yaml
    └── logging/
        ├── elasticsearch-deployment.yaml
        ├── elasticsearch-service.yaml
        ├── kibana-deployment.yaml
        ├── kibana-setup-job.yaml
        ├── kibana-service.yaml
        ├── filebeat-daemonset.yaml
        ├── filebeat-configmap.yaml
        ├── filebeat-serviceaccount.yaml
        ├── filebeat-clusterrole.yaml
        └── filebeat-clusterrolebinding.yaml
```

### Key Helm commands

```bash
# Render templates without deploying (validate before apply)
helm template retail-store helm/retail-store

# Install fresh
helm install retail-store helm/retail-store

# Upgrade (rolling update, idempotent)
helm upgrade --install retail-store helm/retail-store \
  --set imageTag=abc123sha

# Override with a values file (e.g. prod sizing)
helm upgrade --install retail-store helm/retail-store \
  -f helm/retail-store/values-prod.yaml

# View deployed releases
helm list
helm history retail-store

# Rollback to previous release
helm rollback retail-store 1

# Uninstall
helm uninstall retail-store
```

### How the deployment template loops

```yaml
# templates/deployment.yaml
{{- range $name, $svc := .Values.services }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
spec:
  template:
    spec:
      containers:
        - name: {{ $name }}
          image: {{ $.Values.imageRegistry }}/{{ $svc.image }}:{{ $.Values.imageTag }}
          ports:
            - containerPort: {{ $svc.port }}
          env:
            {{- range $k, $v := $svc.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
{{- end }}
```

One template → 5 Deployments (catalog, cart, orders, checkout, ui).
Adding a new service = add one entry to `values.yaml`.

---

## 8. Service Discovery — CoreDNS vs Cloud Map

### ECS approach: Cloud Map

```
catalog.dev.local  →  AWS Cloud Map  →  10.0.1.45 (catalog task private IP)
cart.dev.local     →  AWS Cloud Map  →  10.0.2.67 (cart task private IP)
```

Each ECS service registers itself with Cloud Map on startup.
Other services resolve `http://catalog.dev.local:8080`.

### EKS approach: CoreDNS (built into Kubernetes)

```
catalog.default.svc.cluster.local  →  ClusterIP  →  catalog pods
cart.default.svc.cluster.local     →  ClusterIP  →  cart pods
```

Every Kubernetes Service automatically gets a DNS entry.
Format: `{service}.{namespace}.svc.cluster.local`
Shorthand within same namespace: just `catalog` or `http://catalog`

### In our Helm chart values.yaml

```yaml
services:
  ui:
    env:
      RETAIL_UI_ENDPOINTS_CATALOG:  "http://catalog"    # K8s DNS
      RETAIL_UI_ENDPOINTS_CARTS:    "http://cart"
      RETAIL_UI_ENDPOINTS_CHECKOUT: "http://checkout"
      RETAIL_UI_ENDPOINTS_ORDERS:   "http://orders"
```

Compare to ECS (`terraform/environments/dev/main.tf`):
```hcl
environment_vars = {
  RETAIL_UI_ENDPOINTS_CATALOG = "http://catalog.dev.local:8080"   # Cloud Map
}
```

### Key difference

| | Cloud Map | CoreDNS |
|---|---|---|
| Setup | Explicit Terraform resource per service | Automatic — every K8s Service gets DNS |
| Address | IP:port (A record only, no port in DNS) | Service name only (port from Service spec) |
| URL format | `http://catalog.dev.local:8080` | `http://catalog` |
| Failure mode | Service not registered → NXDOMAIN | Service not created → NXDOMAIN |

---

## 9. Logging — Filebeat DaemonSet vs FireLens

### ECS approach: FireLens sidecar

```
ECS Task:
  ├── app container → stdout
  └── log_router (Fluent Bit) ← reads app stdout → sends to Elasticsearch
```

One Fluent Bit container per task. Configured via `awsfirelens` log driver.
Cost: extra CPU/memory per task for the sidecar.

### EKS approach: Filebeat DaemonSet

```
Node 1:                         Node 2:
  ├── catalog pod → log file    ├── ui pod → log file
  ├── cart pod → log file       ├── orders pod → log file
  └── filebeat pod              └── filebeat pod
      ↓ reads /var/log/containers/     ↓ reads /var/log/containers/
      → Elasticsearch                 → Elasticsearch
```

One Filebeat pod per node (DaemonSet). Reads all container logs from the node's filesystem.
Cost: one Filebeat per node regardless of pod count — more efficient at scale.

### DaemonSet resource

```yaml
apiVersion: apps/v1
kind: DaemonSet    # one pod on EVERY node, always
metadata:
  name: filebeat
spec:
  selector:
    matchLabels:
      app: filebeat
  template:
    spec:
      containers:
        - name: filebeat
          image: elastic/filebeat:8.13.0
          volumeMounts:
            - name: varlog
              mountPath: /var/log          # reads all container logs
            - name: config
              mountPath: /usr/share/filebeat/filebeat.yml
      volumes:
        - name: varlog
          hostPath:
            path: /var/log                 # node filesystem mount
        - name: config
          configMap:
            name: filebeat-config
```

### RBAC for Filebeat

Filebeat needs to read Kubernetes metadata (pod name, namespace, labels) to enrich logs.
This requires ClusterRole permissions:

```yaml
# In our helm/retail-store/templates/logging/filebeat-clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: filebeat
rules:
  - apiGroups: [""]
    resources: [pods, namespaces, nodes]
    verbs: [get, watch, list]
```

Without this: Filebeat cannot enrich logs with pod metadata → harder to filter in Kibana.

---

## 10. CI/CD with GitHub Actions

### Workflow: `eks-deploy.yml`

**Trigger:** push to `feat/eks` or `main`, paths `src/**` or `helm/**`

```
detect-changes
    │
    ├─── no changes → skip
    │
    └─── changed services →
         build (matrix per service)
             │
             ├── Set up runtime (Go/Java/Node)
             ├── Docker build
             ├── Trivy scan (CRITICAL CVEs)
             └── Push :{sha} + :latest
                     │
                     └── eks-deploy
                             │
                             ├── Configure AWS (OIDC)
                             ├── aws eks update-kubeconfig
                             ├── helm upgrade --install ingress-nginx (idempotent)
                             ├── helm upgrade --install retail-store --set imageTag={sha}
                             ├── Wait for ingress address (NLB hostname)
                             └── Smoke test all 6 endpoints
```

### Key design decisions in eks-deploy.yml

**`helm upgrade --install` (not `helm install`):**
- Idempotent — safe to run on every push
- If chart already installed: upgrade it
- If not installed: install it
- No "already exists" errors

**SHA-pinned image tag:**
```yaml
helm upgrade --install retail-store helm/retail-store \
  --set imageTag=${{ github.sha }}
```
Each deploy is pinned to the exact git SHA. Rollback = `helm rollback retail-store 1`.

**Concurrency guard:**
```yaml
concurrency:
  group: eks-deploy
  cancel-in-progress: false   # second deploy queues, doesn't cancel first
```

**OIDC auth (same role as ECS):**
```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.AWS_ROLE_ARN }}
    aws-region: ${{ vars.AWS_REGION }}
```
The GitHub Actions IAM role needs additional EKS permissions:
```json
["eks:DescribeCluster", "eks:ListClusters"]
```

**Smoke test via ingress:**
```bash
ADDR=$(kubectl get ingress retail-store \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ADDR/
curl http://$ADDR/catalogue
```

### ECS deploy vs EKS deploy — comparison

| Step | ECS (`cicd.yml`) | EKS (`eks-deploy.yml`) |
|---|---|---|
| Auth | OIDC → IAM role | OIDC → IAM role (same) |
| Image | Push :{sha} to Docker Hub | Push :{sha} to Docker Hub (same) |
| Deploy | `aws ecs describe-task-definition` → render → register → update service | `helm upgrade --install` |
| Wait | `aws ecs wait services-stable` | `helm --wait --timeout 10m` |
| Health check | `curl http://$ALB/$health_path` | `curl http://$INGRESS/` |
| Rollback | `aws ecs update-service --task-definition :N-1` | `helm rollback retail-store 1` |
| Audit trail | ECS task definition revisions | `helm history retail-store` |

---

## 11. ECS vs EKS — Side-by-Side Comparison

### This project specifically

| Concern | ECS (main) | EKS (feat/eks) |
|---|---|---|
| Infra tool | Terraform (ecs-service module) | Terraform (eks-cluster module) |
| Service packaging | Task definition JSON | Helm chart |
| Deploy command | `aws ecs update-service` | `helm upgrade --install` |
| Service discovery | Cloud Map (`catalog.dev.local:8080`) | CoreDNS (`http://catalog`) |
| Ingress | ALB (Terraform listener rules) | NGINX ingress controller |
| Log routing | FireLens sidecar (Fluent Bit) | Filebeat DaemonSet |
| IAM for pods | ECS task role | IRSA (ServiceAccount annotation) |
| Secrets | SSM Parameter Store | SSM via External Secrets Operator (or K8s Secret) |
| Networking | Fargate (no nodes to manage) | EC2 nodes (t3.medium) |
| Rollback | `aws ecs update-service --task-definition :N-1` | `helm rollback retail-store 1` |
| Cost | Per task-second | $0.10/hr cluster + EC2 |

### General comparison

| Feature | ECS | EKS |
|---|---|---|
| Setup time | ~30 min | ~60 min |
| Operational overhead | Low | Medium |
| Ecosystem | AWS-only | CNCF: Helm, ArgoCD, Istio, Karpenter |
| GitOps | Manual or CodePipeline | ArgoCD, Flux |
| Autoscaling | ECS Service Auto Scaling | HPA, KEDA, Karpenter |
| Multi-tenancy | Limited | Namespaces, RBAC |
| Job scheduling | ECS Scheduled Tasks | CronJob |
| Init containers | Not supported | Supported |
| Sidecar injection | Manual (task definition) | Istio/Linkerd automatic injection |

---

## 12. Common Issues & Fixes

### Issue: Nodes NotReady after cluster creation

```
kubectl get nodes → STATUS = NotReady
```

**Cause:** vpc-cni add-on not ready, or node group still initializing.

**Fix:** Wait 5 minutes. Check:
```bash
kubectl get pods -n kube-system
kubectl describe node <node-name>
```

---

### Issue: Ingress has no ADDRESS

```
kubectl get ingress
NAME           CLASS   HOSTS   ADDRESS   PORTS   AGE
retail-store   nginx   *                 80      2m
```

**Cause:** NGINX ingress controller not installed, or subnet tags missing.

**Fix:**
```bash
# Check ingress controller is running
kubectl get pods -n ingress-nginx

# Check subnet tags
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'Subnets[*].{ID:SubnetId,Tags:Tags}'
# Look for kubernetes.io/role/elb = 1 on public subnets
```

---

### Issue: Pods pending — insufficient resources

```
kubectl describe pod catalog-xxx → 0/2 nodes are available: insufficient memory
```

**Cause:** All pods' memory requests exceed node capacity.

**t3.medium capacity:** 4GB RAM. After system pods (~600MB), ~3.4GB available.
5 app services + ELK stack exceeds this on 2 nodes.

**Fix:**
- Reduce `resources.requests.memory` in `values.yaml`
- Or add a third node: `node_desired = 3` in `terraform.tfvars`
- Or split ELK to a separate node group

---

### Issue: `helm upgrade` fails — resource already exists

```
Error: rendered manifests contain a resource that already exists.
Use --force to recreate or --replace to overwrite.
```

**Cause:** A resource was created with `kubectl apply` before Helm, so Helm doesn't own it.

**Fix:**
```bash
# Delete the conflicting resource and let Helm recreate it
kubectl delete deployment catalog
helm upgrade --install retail-store helm/retail-store
```

---

### Issue: IRSA not working — AccessDeniedException

```
An error occurred (AccessDeniedException) when calling DynamoDB operation...
```

**Cause:** ServiceAccount annotation missing or trust policy condition wrong.

**Fix:**
```bash
# Check ServiceAccount annotation
kubectl get sa cart -o yaml | grep role-arn

# Check pod's projected token
kubectl exec -it <cart-pod> -- \
  cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token | \
  cut -d. -f2 | base64 -d | python3 -m json.tool | grep sub
# Should show: system:serviceaccount:default:cart
```

---

### Issue: `aws eks update-kubeconfig` fails in CI

```
error: no clusters found
```

**Cause:** GitHub Actions IAM role missing `eks:DescribeCluster` permission.

**Fix:** Add to the GitHub Actions IAM role policy:
```json
{
  "Effect": "Allow",
  "Action": ["eks:DescribeCluster", "eks:ListClusters"],
  "Resource": "*"
}
```

---

## 13. Interview Q&A

---

**Q: What is EKS and how does it differ from self-managed Kubernetes?**

> "EKS is AWS's managed Kubernetes service — AWS runs and maintains the control plane
> (API server, etcd, scheduler, controller manager) across three availability zones
> automatically. You only manage the worker nodes and your workloads.
>
> With self-managed Kubernetes, you'd have to provision the control plane yourself,
> handle etcd backups, manage certificate rotation, and upgrade everything manually.
> EKS eliminates that operational burden. The trade-off is cost — EKS charges $0.10/hour
> for the control plane regardless of how many nodes you run."

---

**Q: What is the difference between EKS and ECS?**

> "Both run containers on AWS, but they're different orchestrators. ECS is AWS's proprietary
> service — simpler, deeply integrated with AWS (ALB, Cloud Map, IAM), but AWS-only.
> EKS runs standard Kubernetes — more complex to set up, but portable, with a huge ecosystem:
> Helm for packaging, ArgoCD for GitOps, Istio for service mesh, Karpenter for autoscaling.
>
> In my project I deployed the same application both ways. The key differences I experienced:
> ECS uses Cloud Map for service discovery and FireLens for logging. EKS uses CoreDNS (built in)
> and a Filebeat DaemonSet. ECS uses task roles for IAM; EKS uses IRSA — ServiceAccount
> annotations that let pods assume IAM roles without credentials."

---

**Q: What is IRSA and why do you need it?**

> "IRSA stands for IAM Roles for Service Accounts. In Kubernetes, pods don't have IAM identities
> by default — unlike ECS task roles which are automatic. IRSA solves this using OIDC federation:
> EKS has an OIDC issuer URL, and AWS IAM trusts it. You create an IAM role with a trust policy
> that says 'allow the Kubernetes ServiceAccount named cart in the default namespace to assume
> this role.' The pod's ServiceAccount is annotated with the role ARN, and the AWS SDK
> automatically exchanges a Kubernetes token for temporary AWS credentials.
>
> The result is the same as ECS task roles: no credentials in code, no secrets to rotate,
> pod-level AWS access. In my project, the cart service uses IRSA to access DynamoDB."

---

**Q: What is a DaemonSet and when do you use it?**

> "A DaemonSet ensures that one pod runs on every node in the cluster, automatically.
> When a new node joins, the DaemonSet pod is scheduled on it. When a node is removed,
> the pod is cleaned up. It's the right primitive for node-level infrastructure concerns
> that need to be everywhere.
>
> Common use cases: log collectors (Filebeat, Fluent Bit) that read container log files
> from the node filesystem, monitoring agents (Prometheus node-exporter), security scanners,
> CNI plugins. In my project, Filebeat runs as a DaemonSet — one per node, reads all
> container logs from `/var/log/containers/`, and ships to Elasticsearch."

---

**Q: What is an Ingress and an Ingress Controller?**

> "An Ingress is a Kubernetes resource that defines HTTP routing rules — which paths go
> to which services. It's just configuration — it doesn't do anything on its own.
>
> An Ingress Controller is the actual implementation that reads Ingress resources and
> configures a load balancer accordingly. NGINX Ingress Controller reads your Ingress rules
> and programs an NGINX proxy; it also provisions a Network Load Balancer on AWS automatically.
> AWS Load Balancer Controller reads Ingress resources with the `alb` class and provisions
> an Application Load Balancer directly.
>
> In my project I use NGINX ingress because the Helm chart was written for it — it routes
> `/` to ui, `/catalogue` to catalog, `/kibana` to Kibana, and `/grafana` to Grafana.
> The path rewrite annotation strips the prefix before forwarding to the service."

---

**Q: What is a Helm chart and why use it instead of raw YAML?**

> "Helm is the package manager for Kubernetes. A chart is a collection of YAML templates
> with variables — you render them with specific values using `helm install` or `helm upgrade`.
>
> For my project, instead of 5 separate Deployment YAML files, I have one template that
> loops over a services map in `values.yaml`. Adding a new service means adding one entry
> to `values.yaml` — no new YAML files.
>
> The bigger advantage is lifecycle management. `helm list` shows all deployed releases.
> `helm history retail-store` shows every deploy with timestamps. `helm rollback retail-store 1`
> reverts to the previous release in one command. With raw `kubectl apply`, rollback means
> manually re-applying old YAML — error-prone and untracked."

---

**Q: How does Kubernetes service discovery work?**

> "Every Kubernetes Service automatically gets a DNS entry from CoreDNS:
> `{service-name}.{namespace}.svc.cluster.local`. Within the same namespace, pods can
> just use the service name — `http://catalog` resolves to the catalog Service's ClusterIP.
>
> The ClusterIP is a virtual IP — kube-proxy on each node programs iptables rules that
> load-balance traffic from the ClusterIP to the actual pod IPs. When a pod is added or
> removed, the Endpoints object updates automatically, and kube-proxy reprograms iptables.
>
> This is different from ECS Cloud Map: Cloud Map gives you an A record pointing to
> the task's actual private IP, which means you need to specify the port explicitly.
> K8s DNS handles port through the Service spec — cleaner URLs."

---

**Q: What is the difference between liveness, readiness, and startup probes?**

> "All three are health checks, but they trigger different actions:
>
> Readiness probe: 'is this pod ready to receive traffic?' If it fails, the pod is removed
> from the Service endpoints — no traffic is sent, but the pod keeps running. This is
> critical for slow-starting JVM services: they need 30-60 seconds to load before they
> can handle requests.
>
> Liveness probe: 'is this pod still alive?' If it fails repeatedly, Kubernetes restarts
> the container. Use this to recover from deadlocks or stuck states that wouldn't self-resolve.
>
> Startup probe: 'has this pod finished starting up?' It disables liveness checks until
> it passes, preventing premature restarts during a slow startup. Useful for Java services
> with long initialization times."

---

**Q: What happens when you run `helm upgrade --install retail-store helm/retail-store --set imageTag=abc123`?**

> "Helm renders all the templates with the new imageTag value, then diffs against the
> currently deployed resources. It applies only the changed resources — in this case,
> the Deployments whose image tag changed.
>
> Kubernetes then does a rolling update: it starts new pods with the new image, waits
> for their readiness probe to pass, then terminates old pods. The `--wait` flag makes
> Helm block until all pods are ready. The `--timeout 10m` sets a deadline — if pods
> aren't ready in 10 minutes, the upgrade fails and Helm marks the release as failed
> (you can then run `helm rollback` to revert).
>
> Each `helm upgrade` creates a new release revision stored as a Kubernetes Secret,
> which is how `helm history` and `helm rollback` work."

---

**Q: How is deploying to EKS different from deploying to ECS in your CI/CD pipeline?**

> "The build and push steps are identical — Docker build, Trivy scan, push to Docker Hub
> with the git SHA as the tag. The difference is in the deploy step.
>
> For ECS, I download the current task definition JSON, render a new version with the
> updated image tag using `aws-actions/amazon-ecs-render-task-definition`, register a
> new task definition revision, then update the ECS service. Rollback means pointing the
> service at the previous revision number.
>
> For EKS, I run `aws eks update-kubeconfig` to configure kubectl, then `helm upgrade --install`
> with `--set imageTag={sha}`. Helm handles the rolling update, waits for pods to be ready,
> and records the release history. Rollback is `helm rollback retail-store 1`.
>
> EKS is simpler in the CI/CD step but requires more upfront infrastructure — the cluster,
> node groups, NGINX ingress controller, and IRSA all need to be in place first."

---

*Last updated: 2026-04 | Branch: feat/eks*

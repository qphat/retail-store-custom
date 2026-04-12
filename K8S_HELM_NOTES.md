# Kubernetes & Helm Notes

Personal learning notes built while deploying the retail-store-sample-app on Kind.

---

## Table of Contents

1. [Kubernetes Core Concepts](#1-kubernetes-core-concepts)
2. [Pod](#2-pod)
3. [Deployment](#3-deployment)
4. [Service](#4-service)
5. [Ingress](#5-ingress)
6. [ConfigMap & Secret](#6-configmap--secret)
7. [Probes](#7-probes)
8. [Resource Limits](#8-resource-limits)
9. [Namespaces](#9-namespaces)
10. [Kind - Local Kubernetes](#10-kind---local-kubernetes)
11. [kubectl Cheatsheet](#11-kubectl-cheatsheet)
12. [Helm Core Concepts](#12-helm-core-concepts)
13. [Helm Chart Structure](#13-helm-chart-structure)
14. [Helm Templates & Functions](#14-helm-templates--functions)
15. [Helm Commands Cheatsheet](#15-helm-commands-cheatsheet)
16. [Interview Q&A - Kubernetes](#16-interview-qa---kubernetes)
17. [Interview Q&A - Helm](#17-interview-qa---helm)

---

## 1. Kubernetes Core Concepts

Kubernetes (K8s) is a container orchestrator — it runs your containers, restarts them if they crash, scales them up/down, and routes traffic between them.

### Architecture

```
┌─────────────────────────────────────────────┐
│                  Cluster                    │
│                                             │
│  ┌──────────────┐    ┌────────────────────┐ │
│  │ Control Plane│    │    Worker Nodes    │ │
│  │              │    │                    │ │
│  │ API Server   │    │  ┌─────┐ ┌─────┐   │ │
│  │ Scheduler    │──▶│  │ Pod │ │ Pod │   │ │
│  │ etcd         │    │  └─────┘ └─────┘   │ │
│  │ Controller   │    │                    │ │
│  └──────────────┘    └────────────────────┘ │
└─────────────────────────────────────────────┘
```

- **API Server** — everything goes through here (kubectl, CI/CD, controllers)
- **Scheduler** — decides which node a pod runs on
- **etcd** — stores all cluster state (key-value store)
- **Controller Manager** — watches state, reconciles desired vs actual (e.g. keeps 3 replicas running)
- **kubelet** — agent on each node, runs the containers
- **kube-proxy** — handles networking rules on each node

### Key Design Principle: Declarative

You declare **what you want** (3 replicas of catalog), not **how to do it**.
K8s continuously reconciles actual state → desired state.

```
Desired state (your YAML) ──▶ K8s reconciliation loop ──▶ Actual state
```

---

## 2. Pod

The smallest deployable unit in K8s. A pod wraps one or more containers that share:
- Network namespace (same IP, communicate via localhost)
- Storage volumes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: catalog
spec:
  containers:
    - name: catalog
      image: koomi1/retail-app-catalog:latest
      ports:
        - containerPort: 8080
```

### Why not deploy Pods directly?

Pods are **ephemeral** — if a pod crashes, it's gone. No restart, no replacement.
Use a **Deployment** to manage pods instead.

---

## 3. Deployment

A Deployment manages a set of identical pods (replicas). It:
- Creates pods from a template
- Restarts pods if they crash
- Rolls out updates (rolling update by default)
- Rolls back if something goes wrong

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  replicas: 3                    # run 3 pods
  selector:
    matchLabels:
      app: catalog               # manage pods with this label
  template:                      # pod template
    metadata:
      labels:
        app: catalog
    spec:
      containers:
        - name: catalog
          image: koomi1/retail-app-catalog:latest
          ports:
            - containerPort: 8080
```

### Rolling Update Strategy (default)

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # create 1 extra pod during update
    maxUnavailable: 0  # never take a pod down before new one is ready
```

When you push a new image:
1. K8s creates a new pod with the new image
2. Waits for it to pass readinessProbe
3. Terminates one old pod
4. Repeats until all old pods are replaced

Zero downtime deployment.

### Why `selector.matchLabels` must match `template.labels`

The Deployment uses labels to find "its" pods. If they don't match, the Deployment can't manage the pods.

---

## 4. Service

Pods get a random IP that changes every restart. A **Service** gives a stable DNS name and IP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: catalog           # DNS name: catalog.default.svc.cluster.local
spec:
  selector:
    app: catalog          # route to pods with this label
  ports:
    - port: 80            # port the Service listens on (inside cluster)
      targetPort: 8080    # port the container listens on
```

### Service Types

| Type | Use case |
|---|---|
| `ClusterIP` (default) | Internal only — pod-to-pod communication |
| `NodePort` | Exposes on a static port on every node (30000-32767) |
| `LoadBalancer` | Creates a cloud load balancer (AWS ALB, GCP LB) |
| `ExternalName` | Maps to an external DNS name |

### K8s DNS

Every Service gets a DNS name automatically:
```
<service-name>.<namespace>.svc.cluster.local
```

In the same namespace you can just use the service name:
```
http://catalog        # resolves to catalog Service IP
http://cart           # resolves to cart Service IP
```

That's why `RETAIL_UI_ENDPOINTS_CATALOG=http://catalog` works — K8s DNS resolves `catalog` to the Service IP.

---

## 5. Ingress

A Service with `ClusterIP` is not accessible from outside the cluster.
**Ingress** is an API object that defines routing rules for external HTTP/HTTPS traffic.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: retail-store
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx      # which ingress controller handles this
  rules:
    - host: myapp.example.com  # optional: route by hostname
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ui
                port:
                  number: 80
```

### Ingress Controller

The Ingress object is just a rule. You need an **Ingress Controller** to actually process it.
Common choices:
- **nginx** — most popular, works everywhere
- **Traefik** — good for dynamic environments
- **AWS ALB Controller** — creates an AWS Application Load Balancer

### Path-based routing example

```yaml
rules:
  - http:
      paths:
        - path: /api/catalog
          backend:
            service:
              name: catalog
        - path: /api/cart
          backend:
            service:
              name: cart
        - path: /
          backend:
            service:
              name: ui
```

---

## 6. ConfigMap & Secret

### ConfigMap — non-sensitive config

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  RETAIL_CHECKOUT_PERSISTENCE_PROVIDER: "in-memory"
  RETAIL_CHECKOUT_ENDPOINTS_ORDERS: "http://orders"
```

Use in Deployment:
```yaml
envFrom:
  - configMapRef:
      name: checkout-config
```

Or single key:
```yaml
env:
  - name: RETAIL_CHECKOUT_ENDPOINTS_ORDERS
    valueFrom:
      configMapKeyRef:
        name: checkout-config
        key: RETAIL_CHECKOUT_ENDPOINTS_ORDERS
```

### Secret — sensitive config (passwords, tokens)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: orders-db-secret
type: Opaque
stringData:                    # K8s base64-encodes these automatically
  DB_PASSWORD: "mysecretpass"
```

Use in Deployment:
```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: orders-db-secret
        key: DB_PASSWORD
```

### ConfigMap vs Secret

| | ConfigMap | Secret |
|---|---|---|
| Use for | URLs, flags, non-sensitive config | Passwords, tokens, keys |
| Stored as | Plaintext in etcd | Base64 in etcd (not encrypted by default) |
| Shown in kubectl | Yes | No (masked) |

> Note: Secrets are only base64 encoded, not encrypted. For real security use **Sealed Secrets** or **External Secrets Operator** with AWS SSM / Vault.

---

## 7. Probes

K8s uses probes to know if a container is healthy.

### readinessProbe — is the app ready to receive traffic?

K8s does NOT send traffic to a pod until readinessProbe passes.
Use for: waiting for Spring Boot to start, DB connections to initialize.

```yaml
readinessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 15   # wait 15s before first check
  periodSeconds: 10          # check every 10s
  failureThreshold: 3        # fail 3 times before marking unready
```

### livenessProbe — is the app still alive?

If livenessProbe fails, K8s **restarts** the container.
Use for: detecting deadlocks, hung processes.

```yaml
livenessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 20
```

### startupProbe — for slow-starting apps

Disables liveness/readiness until the app starts. Prevents K8s from killing a slow-starting app.

```yaml
startupProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  failureThreshold: 30   # allow up to 30 * 10s = 5 minutes to start
  periodSeconds: 10
```

### Probe types

| Type | Use case |
|---|---|
| `httpGet` | HTTP endpoint returns 2xx/3xx |
| `exec` | Run a command, exit 0 = healthy |
| `tcpSocket` | TCP connection succeeds |
| `grpc` | gRPC health check |

---

## 8. Resource Limits

```yaml
resources:
  requests:            # minimum guaranteed resources
    cpu: 100m          # 100 millicores = 0.1 CPU
    memory: 128Mi
  limits:              # maximum allowed
    cpu: 500m
    memory: 256Mi
```

### requests vs limits

- **requests** — used by the scheduler to decide which node to place the pod on
- **limits** — hard cap; container is throttled (CPU) or killed (memory OOM) if exceeded

### CPU units

- `1` = 1 full CPU core
- `500m` = 0.5 CPU
- `100m` = 0.1 CPU (100 millicores)

### Memory units

- `256Mi` = 256 mebibytes
- `1Gi` = 1 gibibyte

### QoS Classes

| Class | Condition | Behavior |
|---|---|---|
| `Guaranteed` | requests == limits | Last to be evicted |
| `Burstable` | requests < limits | Evicted if node is under pressure |
| `BestEffort` | no requests/limits | First to be evicted |

---

## 9. Namespaces

Namespaces are virtual clusters inside a physical cluster. Used to separate environments or teams.

```bash
kubectl create namespace staging
kubectl apply -f k8s/ -n staging
kubectl get pods -n staging
```

By default everything goes to `default` namespace.

Common pattern:
```
default     → dev/learning
staging     → pre-prod
production  → prod
monitoring  → prometheus, grafana
```

---

## 10. Kind - Local Kubernetes

Kind (Kubernetes in Docker) runs K8s nodes as Docker containers on your machine.

### Create cluster with port mappings (so localhost:80 works)

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443
```

```bash
kind create cluster --name retail --config kind-config.yaml
```

### Load local images (avoid pulling from registry)

```bash
docker pull koomi1/retail-app-catalog:latest
kind load docker-image koomi1/retail-app-catalog:latest --name retail
```

Then set `imagePullPolicy: Never` in the Deployment.

### Install nginx ingress for Kind

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

---

## 11. kubectl Cheatsheet

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes

# Pods
kubectl get pods                        # list pods in default namespace
kubectl get pods -n ingress-nginx       # list in specific namespace
kubectl get pods -w                     # watch (live updates)
kubectl describe pod <name>             # full details + events
kubectl logs <name>                     # container logs
kubectl logs <name> -f                  # follow logs
kubectl logs <name> --previous          # logs from previous (crashed) container
kubectl exec -it <name> -- sh           # shell into container

# Deployments
kubectl get deployments
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>  # rollback

# Services & Ingress
kubectl get svc
kubectl get ingress

# Apply & Delete
kubectl apply -f file.yaml
kubectl apply -f directory/
kubectl delete -f file.yaml
kubectl delete pod <name>               # pod restarts (managed by Deployment)
kubectl delete deployment <name>        # removes deployment + pods

# Debug
kubectl get events --sort-by=.lastTimestamp
kubectl port-forward svc/<name> 8080:80

# Scale
kubectl scale deployment <name> --replicas=3
```

---

## 12. Helm Core Concepts

Helm is the package manager for Kubernetes.

| Concept | Analogy | Description |
|---|---|---|
| Chart | npm package | A bundle of K8s templates |
| Release | installed package | A deployed instance of a chart |
| Values | config | Variables injected into templates |
| Repository | npm registry | Where charts are stored |

### Why Helm?

Without Helm you copy-paste YAML for every service. With Helm:
- Write the template once
- Deploy 5 services with different values
- Upgrade all services with one command
- Rollback with one command
- Package and share charts

---

## 13. Helm Chart Structure

```
retail-store/
├── Chart.yaml          # chart metadata (name, version, description)
├── values.yaml         # default values
└── templates/
    ├── deployment.yaml # K8s templates with {{ .Values.* }}
    ├── service.yaml
    ├── ingress.yaml
    └── _helpers.tpl    # reusable template functions (optional)
```

### Chart.yaml

```yaml
apiVersion: v2
name: retail-store
description: AWS Containers Retail Store sample app
version: 0.1.0        # chart version (increment when chart changes)
appVersion: "latest"  # app version (informational)
```

### values.yaml

Default values — users can override with `--set` or `-f custom-values.yaml`:

```yaml
imageRegistry: koomi1
imageTag: latest
replicas: 1
```

---

## 14. Helm Templates & Functions

Templates are Go templates with Helm extensions.

### Basic value injection

```yaml
image: {{ .Values.imageRegistry }}/{{ .Values.image }}:{{ .Values.imageTag }}
```

### Built-in objects

| Object | Contains |
|---|---|
| `.Values` | values.yaml + --set overrides |
| `.Release` | release name, namespace, revision |
| `.Chart` | Chart.yaml contents |

### Common functions

```yaml
# quote — wrap in quotes (important for strings that look like numbers)
value: {{ .Values.port | quote }}

# default — fallback value
replicas: {{ .Values.replicas | default 1 }}

# toYaml — convert a map/list to YAML (use with nindent)
resources:
  {{- toYaml .Values.resources | nindent 2 }}

# nindent — indent N spaces with leading newline
labels:
  {{- include "retail-store.labels" . | nindent 4 }}

# range — loop over a map or list
{{- range $key, $val := .Values.env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}

# if/else
{{- if .Values.ingress.enabled }}
...ingress yaml...
{{- end }}
```

### Template whitespace control

- `{{-` — trim whitespace/newline BEFORE the tag
- `-}}` — trim whitespace/newline AFTER the tag

```yaml
# Without trim — extra blank lines in output
{{ if .Values.enabled }}
value: true
{{ end }}

# With trim — clean output
{{- if .Values.enabled }}
value: true
{{- end }}
```

### `range` with `$` for parent scope

Inside `range`, `.` becomes the current item. Use `$` to access root:

```yaml
{{- range $name, $svc := .Values.services }}
image: {{ $.Values.imageRegistry }}/{{ $svc.image }}  # $ = root scope
{{- end }}
```

---

## 15. Helm Commands Cheatsheet

```bash
# Install
helm install <release-name> <chart-path>
helm install retail-store ./helm/retail-store

# Override values
helm install retail-store ./helm/retail-store \
  --set imageTag=abc123 \
  --set services.catalog.replicas=2

# Override with a file
helm install retail-store ./helm/retail-store -f custom-values.yaml

# Upgrade (update running release)
helm upgrade retail-store ./helm/retail-store
helm upgrade retail-store ./helm/retail-store --set imageTag=newsha

# Upgrade or install (idempotent)
helm upgrade --install retail-store ./helm/retail-store

# Rollback
helm rollback retail-store 1    # rollback to revision 1
helm rollback retail-store      # rollback to previous revision

# List releases
helm list
helm list -n staging            # in specific namespace

# Status
helm status retail-store

# History
helm history retail-store

# Uninstall
helm uninstall retail-store

# Dry run (see what would be deployed)
helm install retail-store ./helm/retail-store --dry-run

# Render templates locally (no cluster needed)
helm template retail-store ./helm/retail-store

# Lint (check for errors)
helm lint ./helm/retail-store

# Add a chart repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/postgresql
```

---

## 16. Interview Q&A - Kubernetes

**Q: What is the difference between a Pod and a Deployment?**

A Pod is a single instance of a container — if it crashes, it's gone. A Deployment manages a set of identical pods: it restarts crashed pods, maintains the desired replica count, and handles rolling updates. You almost never create Pods directly in production.

---

**Q: What is the difference between readinessProbe and livenessProbe?**

- `readinessProbe` — controls traffic. K8s won't send traffic to a pod until it passes. Used for slow-starting apps (Spring Boot takes 20-30s).
- `livenessProbe` — controls restarts. If it fails, K8s kills and restarts the container. Used to detect deadlocks or hung processes.

Rule of thumb: readiness = "is it ready to serve?", liveness = "is it still alive?"

---

**Q: How does service discovery work in Kubernetes?**

K8s has a built-in DNS (CoreDNS). Every Service gets a DNS record: `<service-name>.<namespace>.svc.cluster.local`. In the same namespace you can just use the service name. So `http://catalog` in a container resolves to the `catalog` Service IP, which load-balances across all catalog pods.

---

**Q: What is the difference between ClusterIP, NodePort, and LoadBalancer?**

- `ClusterIP` — only accessible inside the cluster (pod-to-pod). Default.
- `NodePort` — exposes on a static port on every node. Accessible from outside but not production-grade (fixed ports 30000-32767).
- `LoadBalancer` — provisions a cloud load balancer (AWS ALB/NLB). The production way to expose services.

For HTTP routing, use `Ingress` instead of LoadBalancer per service — one load balancer for all services.

---

**Q: What happens when you do `kubectl apply -f deployment.yaml`?**

1. kubectl sends the manifest to the API Server
2. API Server validates and stores it in etcd
3. Controller Manager detects the desired state changed
4. Scheduler assigns pods to nodes
5. kubelet on the node pulls the image and starts the container
6. kube-proxy updates networking rules

---

**Q: How do rolling updates work?**

With `RollingUpdate` strategy: K8s creates a new pod with the new image, waits for its readinessProbe to pass, then terminates one old pod. Repeats until all old pods are replaced. `maxSurge` controls how many extra pods are created, `maxUnavailable` controls how many can be down at once. Setting `maxUnavailable: 0` means zero downtime.

---

**Q: What is a ConfigMap and when would you use a Secret instead?**

ConfigMap stores non-sensitive configuration (URLs, feature flags, app settings). Secret stores sensitive data (passwords, API keys, tokens). Both inject values into containers via env vars or volume mounts. Secrets are base64-encoded in etcd but not encrypted by default — use Sealed Secrets or External Secrets for real security.

---

**Q: What is a namespace and why use it?**

A namespace is a virtual cluster inside a physical cluster. Used to isolate environments (dev/staging/prod), teams, or applications. Resource names only need to be unique within a namespace. RBAC permissions can be scoped to a namespace.

---

**Q: How would you rollback a bad deployment?**

```bash
kubectl rollout history deployment/catalog   # see revisions
kubectl rollout undo deployment/catalog      # rollback to previous
kubectl rollout undo deployment/catalog --to-revision=2  # rollback to specific
```

K8s keeps a history of ReplicaSets, so rollback is instant — no re-deployment needed.

---

**Q: What is the difference between `requests` and `limits` in resources?**

- `requests` — the minimum guaranteed resources. Used by the scheduler to find a node with enough capacity.
- `limits` — the hard cap. CPU is throttled, memory triggers OOM kill.

If you set only `limits` with no `requests`, K8s sets `requests = limits` (Guaranteed QoS). If you set `requests < limits` (Burstable), the pod can use more CPU/memory when available but may be evicted under pressure.

---

## 17. Interview Q&A - Helm

**Q: What is Helm and why use it?**

Helm is the package manager for Kubernetes. It templates K8s YAML files, letting you deploy the same application with different configurations (dev vs prod) without copy-pasting manifests. It also manages releases — you can upgrade, rollback, and track history of deployments.

---

**Q: What is the difference between `helm install` and `helm upgrade --install`?**

`helm install` fails if the release already exists. `helm upgrade --install` is idempotent — installs if not exists, upgrades if it does. Use `upgrade --install` in CI/CD pipelines.

---

**Q: How do you override values in Helm?**

Three ways, in order of precedence (highest wins):
1. `--set key=value` on the command line
2. `-f custom-values.yaml` file
3. Default `values.yaml` in the chart

---

**Q: What is `helm template` used for?**

Renders the chart templates locally and prints the YAML output without connecting to a cluster. Useful for:
- Debugging templates
- Reviewing what will be deployed
- Generating static YAML for GitOps (ArgoCD)

---

**Q: What is a Helm repository?**

A repository is a collection of packaged charts (`.tgz` files) hosted on an HTTP server. Common repos:
- `https://charts.bitnami.com/bitnami` — databases, middleware
- `https://charts.helm.sh/stable` — community charts

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install my-postgres bitnami/postgresql
```

---

**Q: How does Helm handle rollbacks?**

Helm stores each release revision in K8s Secrets. `helm rollback <release> <revision>` re-applies the previous manifest set. Unlike `kubectl rollout undo` (which only affects Deployments), Helm rollback restores ALL resources in the chart — Services, ConfigMaps, Secrets, etc.

---

**Q: What is `_helpers.tpl`?**

A file for defining named templates (Go template functions) that can be reused across multiple template files. Convention: prefix with the chart name to avoid collisions.

```yaml
{{- define "retail-store.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end }}
```

Called with: `{{ include "retail-store.fullname" . }}`

---

**Q: What is the difference between `helm upgrade` and `kubectl apply`?**

`kubectl apply` is imperative — applies whatever YAML you give it, no history, no rollback. `helm upgrade` is release-aware — tracks revision history, validates the full chart, and supports rollback. In production, prefer Helm (or GitOps tools like ArgoCD) over raw `kubectl apply`.

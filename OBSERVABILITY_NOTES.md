# Observability Notes

How metrics, logging, and tracing work in this project — from Docker Compose to Kubernetes.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Metrics: Prometheus + Grafana](#2-metrics-prometheus--grafana)
3. [Logging: ELK Stack](#3-logging-elk-stack)
4. [How It Works in Docker Compose](#4-how-it-works-in-docker-compose)
5. [How It Works in Kubernetes](#5-how-it-works-in-kubernetes)
6. [Key Differences: Docker Compose vs Kubernetes](#6-key-differences-docker-compose-vs-kubernetes)
7. [Helm Chart Structure](#7-helm-chart-structure)
8. [Debugging](#8-debugging)
9. [Interview Q&A](#9-interview-qa)

---

## 1. Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Observability Stack                       │
│                                                             │
│  Metrics                    Logging                         │
│  ───────                    ───────                         │
│  App → Prometheus → Grafana  App → Filebeat → ES → Kibana   │
│                                                             │
│  Pull model (Prometheus      Push model (Filebeat reads     │
│  scrapes /metrics endpoint)  log files and ships them)      │
└─────────────────────────────────────────────────────────────┘
```

### What each tool does

| Tool | Role |
|---|---|
| **Prometheus** | Scrapes metrics from services every 15s, stores time-series data |
| **Grafana** | Visualizes Prometheus metrics as dashboards |
| **Filebeat** | Reads container log files, ships them to Elasticsearch |
| **Elasticsearch** | Stores and indexes log data (full-text search) |
| **Kibana** | UI for searching and visualizing logs in Elasticsearch |

---

## 2. Metrics: Prometheus + Grafana

### How Prometheus works

Prometheus uses a **pull model** — it periodically scrapes HTTP endpoints on your services.

```
Every 15s:
Prometheus ──HTTP GET──▶ http://catalog/metrics
           ──HTTP GET──▶ http://cart/actuator/prometheus
           ──HTTP GET──▶ http://orders/actuator/prometheus
           ──HTTP GET──▶ http://checkout/metrics
           ──HTTP GET──▶ http://ui/actuator/prometheus
```

Each service exposes a `/metrics` or `/actuator/prometheus` endpoint that returns data in Prometheus text format:

```
# Go service (catalog, checkout)
http_requests_total{method="GET", status="200"} 42
go_goroutines 8

# Java/Spring Boot service (cart, orders, ui) — via Micrometer
jvm_memory_used_bytes{area="heap"} 1.2e8
http_server_requests_seconds_count{uri="/actuator/health"} 5
```

### How Grafana works

Grafana **does not store data** — it queries Prometheus and displays it.

```
Browser ──▶ Grafana ──PromQL query──▶ Prometheus ──▶ returns data ──▶ Grafana renders chart
```

### Grafana provisioning as code

Instead of clicking through the UI, Grafana can be configured via YAML files at startup:

```
/etc/grafana/provisioning/
  datasources/
    datasources.yml    ← tells Grafana where Prometheus is
  dashboards/
    dashboards.yml     ← tells Grafana where to find JSON dashboard files
    jvm.json           ← JVM Micrometer dashboard
    go.json            ← Go metrics dashboard
```

**datasources.yml:**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: PBFA97CFB590B2093   # pinned UID — dashboard JSONs reference this
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
```

**Why pin the UID?**
Dashboard JSON files hardcode the datasource UID. If Grafana assigns a random UID, dashboards show "datasource not found". Pinning the UID in the provisioning file ensures the dashboard JSON UID always matches.

---

## 3. Logging: ELK Stack

ELK = Elasticsearch + Logstash + Kibana. In this project we use **EFK** — replacing Logstash with **Filebeat** (lighter weight).

### How EFK works

```
Container writes to stdout/stderr
         │
         ▼
Log file on disk (Docker: /var/lib/docker/containers/*.log)
         │         (K8s: /var/log/pods/*/*/*.log)
         ▼
    Filebeat reads file
         │  adds metadata (container name, pod name, namespace)
         │  ships to Elasticsearch
         ▼
  Elasticsearch stores + indexes
         │
         ▼
   Kibana queries and displays
```

### Elasticsearch

- Stores logs as JSON documents in **indices** (like database tables)
- Each index has a pattern: `logs-default-2026.04.06`
- Full-text search across all log fields
- Single-node for dev (no replication)

### Kibana

- UI for exploring logs in Elasticsearch
- Uses **Data Views** to define which indices to search (`logs-*`)
- Main use: filter logs by service, time range, log level, search for errors

### Filebeat

- Lightweight log shipper (written in Go)
- Reads log files, adds metadata, sends to Elasticsearch
- In Docker: reads `/var/lib/docker/containers/*/` via Docker socket
- In K8s: reads `/var/log/containers/` and `/var/log/pods/` via hostPath volume

---

## 4. How It Works in Docker Compose

### Log collection in Docker

When a container writes to stdout/stderr, Docker captures it and writes to a JSON log file:

```
/var/lib/docker/containers/<container-id>/<container-id>-json.log
```

Example content:
```json
{"log":"2026-04-06 INFO Starting catalog service\n","stream":"stdout","time":"2026-04-06T10:00:00Z"}
```

Filebeat reads these files and adds Docker metadata (container name, image, etc.).

### filebeat.yml (Docker Compose version)

```yaml
filebeat.inputs:
  - type: container
    paths:
      - /var/lib/docker/containers/*/*.log

    processors:
      - add_docker_metadata:    # adds container_name, image, etc.
          host: unix:///var/run/docker.sock

processors:
  - drop_fields:
      fields: ["agent", "ecs", "host", "input"]

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "logs-%{[container.name]}-%{+yyyy.MM.dd}"
```

Filebeat in Docker Compose needs:
- **`user: root`** — to read Docker container log files
- **`/var/lib/docker/containers`** volume — the log files
- **`/var/run/docker.sock`** volume — for Docker metadata API

### Kibana data view (auto-provisioned)

The `kibana-setup` container runs a one-shot curl command to create a data view via the Kibana API:

```bash
curl -X POST http://kibana:5601/api/data_views/data_view \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "data_view": {
      "title": ".ds-logs-*",
      "timeFieldName": "@timestamp"
    }
  }'
```

In Docker, Filebeat uses ECS data streams (`.ds-logs-*` pattern). In K8s we disable ILM so the pattern is `logs-*`.

---

## 5. How It Works in Kubernetes

### How K8s handles container logs

When a pod writes to stdout/stderr, the kubelet captures it and writes to the node filesystem:

```
/var/log/pods/<namespace>_<pod-name>_<uid>/<container-name>/0.log
```

Docker also creates symlinks at:
```
/var/log/containers/<pod-name>_<namespace>_<container-name>-<id>.log
  → /var/log/pods/.../0.log
```

Filebeat reads `/var/log/containers/*.log` (the symlinks) and follows them to the actual files.

### Why Filebeat runs as DaemonSet

A **DaemonSet** runs exactly one pod per node. Since log files are on the node's filesystem, you need one Filebeat per node to collect that node's logs.

```
Node 1                    Node 2
┌──────────────────┐      ┌──────────────────┐
│ pod: catalog     │      │ pod: cart        │
│ pod: checkout    │      │ pod: orders      │
│ pod: filebeat ◄──┤      │ pod: filebeat ◄──┤
│   /var/log/pods  │      │   /var/log/pods  │
└──────────────────┘      └──────────────────┘
         │                         │
         └────────────┬────────────┘
                      ▼
               Elasticsearch
```

### filebeat.yml (Kubernetes version)

```yaml
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/*.log    # symlinks on the host node
    processors:
      - add_kubernetes_metadata:     # queries K8s API for pod info
          host: ${NODE_NAME}         # scope to this node
          matchers:
            - logs_path:
                logs_path: "/var/log/containers/"

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "logs-%{[kubernetes.namespace]}-%{+yyyy.MM.dd}"

# Disable ILM — write regular date-based indices, not data streams
setup.ilm.enabled: false
setup.template.name: "logs"
setup.template.pattern: "logs-*"
```

**Key difference from Docker Compose:**
- Docker: `add_docker_metadata` processor + Docker socket
- K8s: `add_kubernetes_metadata` processor + ClusterRole to query K8s API

### RBAC for Filebeat

Filebeat needs to query the K8s API to get pod metadata. This requires:

```yaml
# ServiceAccount — identity for the Filebeat pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: filebeat

# ClusterRole — what the ServiceAccount is allowed to do
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: filebeat
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, nodes]
    verbs: [get, list, watch]

# ClusterRoleBinding — binds the role to the ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: filebeat
subjects:
  - kind: ServiceAccount
    name: filebeat
    namespace: default
roleRef:
  kind: ClusterRole
  name: filebeat
  apiGroup: rbac.authorization.k8s.io
```

Without RBAC, Filebeat can still collect logs — it just can't enrich them with K8s metadata (pod labels, namespace, etc.).

### Elasticsearch: vm.max_map_count

Elasticsearch 8.x requires the kernel parameter `vm.max_map_count >= 262144` (virtual memory areas limit). In K8s, this is set via an **initContainer** that runs before the main container:

```yaml
initContainers:
  - name: set-vm-max-map-count
    image: busybox
    command: ['sysctl', '-w', 'vm.max_map_count=262144']
    securityContext:
      privileged: true   # needs root to set kernel params
```

This runs once, sets the value on the node, then exits. The main Elasticsearch container then starts.

### Prometheus scrape targets in K8s

In Docker Compose, Prometheus scrapes `catalog:8080` directly (container port).

In K8s, traffic goes through the **Service** (ClusterIP), so scrape targets use port 80 (the Service port):

```yaml
# Docker Compose
- targets: ['catalog:8080']

# Kubernetes — goes through ClusterIP Service
- targets: ['catalog:80']
```

The Service routes port 80 → container port 8080 internally.

### Kibana data view (K8s Job)

Instead of a one-shot container in docker-compose, K8s uses a **Job** — a resource that runs a pod to completion.

With Helm hooks, the Job runs *after* all other resources are deployed:

```yaml
metadata:
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

The Job waits for Kibana to be ready, then calls the Kibana API:

```bash
until curl -sf http://kibana:5601/kibana/api/status; do
  sleep 10
done
curl -X POST http://kibana:5601/kibana/api/data_views/data_view \
  -H "kbn-xsrf: true" \
  -d '{"data_view": {"title": "logs-*", "timeFieldName": "@timestamp"}}'
```

### Sub-path ingress routing

Grafana and Kibana are served under `/grafana` and `/kibana` paths via the nginx ingress.

**Problem:** nginx strips the path prefix before forwarding to the service. So a request to `/grafana/dashboard` arrives at Grafana as `/dashboard`. Grafana doesn't know it's at a subpath and generates broken links.

**Solution:** Tell each app it's at a subpath:

```yaml
# Grafana
GF_SERVER_ROOT_URL: "%(protocol)s://%(domain)s/grafana"
GF_SERVER_SERVE_FROM_SUB_PATH: "true"

# Kibana
SERVER_BASEPATH: /kibana
SERVER_REWRITEBASEPATH: "true"
```

**Ingress annotation:**
```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2
```

With capture groups in the path:
```yaml
# Strips /grafana prefix: /grafana/dashboard → /dashboard
- path: /grafana(/|$)(.*)
  pathType: ImplementationSpecific

# Passes everything through for main app
- path: /()(.*)
  pathType: ImplementationSpecific
```

---

## 6. Key Differences: Docker Compose vs Kubernetes

| | Docker Compose | Kubernetes |
|---|---|---|
| Log file location | `/var/lib/docker/containers/` | `/var/log/pods/` and `/var/log/containers/` |
| Filebeat deployment | Single container | DaemonSet (one per node) |
| Filebeat log source | Docker socket + container files | hostPath volumes |
| Metadata processor | `add_docker_metadata` | `add_kubernetes_metadata` |
| Filebeat permissions | `user: root` in compose | `runAsUser: 0` + no ClusterRole needed for logs |
| Metadata permissions | Docker socket access | ClusterRole (RBAC) to query K8s API |
| Index pattern | `.ds-logs-*` (data streams) | `logs-*` (regular indices, ILM disabled) |
| Prometheus targets | `service:8080` (container port) | `service:80` (Service port) |
| Kibana setup | One-shot container (`restart: on-failure`) | K8s Job with Helm `post-install` hook |
| Grafana provisioning | Volume mounts from host | ConfigMap volume mounts |
| Elasticsearch startup | Works out of the box | Needs `vm.max_map_count` initContainer |

---

## 7. Helm Chart Structure

```
helm/retail-store/
├── Chart.yaml
├── values.yaml
├── dashboards/               ← Dashboard JSON files (outside templates/)
│   ├── jvm.json              ← JVM Micrometer dashboard
│   └── go.json               ← Go metrics dashboard
└── templates/
    ├── deployment.yaml       ← 5 app services (range loop)
    ├── service.yaml          ← 5 app services (range loop)
    ├── ingress.yaml          ← routes /, /grafana, /kibana
    ├── monitoring/
    │   ├── prometheus-configmap.yaml       ← prometheus.yml scrape config
    │   ├── prometheus-deployment.yaml
    │   ├── prometheus-service.yaml
    │   ├── grafana-configmap.yaml          ← datasources.yml
    │   ├── grafana-dashboards-configmap.yaml ← dashboards.yml + jvm.json + go.json
    │   ├── grafana-deployment.yaml
    │   └── grafana-service.yaml
    └── logging/
        ├── elasticsearch-deployment.yaml   ← initContainer for vm.max_map_count
        ├── elasticsearch-service.yaml
        ├── kibana-deployment.yaml          ← SERVER_BASEPATH=/kibana
        ├── kibana-service.yaml
        ├── kibana-setup-job.yaml           ← Helm post-install hook
        ├── filebeat-configmap.yaml         ← filebeat.yml with add_kubernetes_metadata
        ├── filebeat-serviceaccount.yaml
        ├── filebeat-clusterrole.yaml
        ├── filebeat-clusterrolebinding.yaml
        └── filebeat-daemonset.yaml         ← hostPath: /var/log/containers + /var/log/pods
```

### Enabling/disabling stacks

```bash
# Monitoring only
helm upgrade retail-store helm/retail-store \
  --set monitoring.enabled=true \
  --set logging.enabled=false

# Logging only
helm upgrade retail-store helm/retail-store \
  --set monitoring.enabled=false \
  --set logging.enabled=true

# Both (default)
helm upgrade retail-store helm/retail-store
```

---

## 8. Debugging

### Prometheus: no data / targets DOWN

```bash
# Check targets
kubectl port-forward svc/prometheus 9090:9090
# http://localhost:9090/targets

# Common causes:
# - Service port mismatch (use :80 not :8080 in K8s)
# - App not exposing metrics endpoint
# - App not ready yet
kubectl logs -l app=catalog | grep metrics
```

### Grafana: "datasource not found" in dashboard

The dashboard JSON references datasource UID `PBFA97CFB590B2093`.
Check the provisioned datasource has the same UID:

```bash
kubectl exec -it $(kubectl get pod -l app=grafana -o name) -- \
  cat /etc/grafana/provisioning/datasources/datasources.yml
```

### Elasticsearch: OOMKilled

ES 8.x needs at least 2Gi memory limit in K8s. The JVM heap (`ES_JAVA_OPTS=-Xms512m -Xmx512m`) is 512m, but ES needs additional memory for OS page cache and JVM overhead.

```bash
kubectl describe pod -l app=elasticsearch | grep -A5 "OOM\|Limits"
```

Fix: increase memory limit in `values.yaml`:
```yaml
elasticsearch:
  resources:
    limits:
      memory: 2Gi
```

### Filebeat: not shipping logs

```bash
kubectl logs -l app=filebeat --tail=50

# Common causes:
# 1. Permission error — needs runAsUser: 0
# 2. Elasticsearch not ready yet — filebeat retries automatically
# 3. strict.perms error — use --strict.perms=false flag
```

### Kibana: data view has no data

```bash
# 1. Check Filebeat is running
kubectl get pods -l app=filebeat

# 2. Check indices exist in Elasticsearch
kubectl port-forward svc/elasticsearch 9200:9200
curl http://localhost:9200/_cat/indices?v

# 3. Check the data view pattern matches index names
# Index: logs-default-2026.04.06
# Pattern: logs-*  ← should match
```

### Kibana setup Job fails

```bash
kubectl logs job/kibana-setup

# Common cause: Kibana not ready when Job ran
# Fix: Job has backoffLimit: 10 with internal wait loop
# Just wait — it retries automatically
```

---

## 9. Interview Q&A

**Q: What is the difference between metrics and logs?**

Metrics are numeric measurements sampled over time — CPU usage, request count, latency percentiles. They are cheap to store and great for alerting and dashboards. Logs are detailed text records of events — they tell you *what happened* and *why*. Metrics tell you *something is wrong*, logs tell you *what is wrong*. You use metrics to detect a problem, then logs to diagnose it.

---

**Q: What is Prometheus's scrape model and why is it better than push?**

Prometheus pulls (scrapes) metrics from services on a schedule. This means Prometheus controls the scrape rate, not the services. Benefits: no need to configure each service with the Prometheus address, services don't need to know about Prometheus, easy to detect when a service is down (scrape fails). Downside: short-lived jobs (batch processes) may finish before being scraped — solved with Pushgateway.

---

**Q: What is a Prometheus data view and how does PromQL work?**

PromQL (Prometheus Query Language) is used to query time-series data. Key concepts:
- `http_requests_total` — instant vector (current value of a metric)
- `http_requests_total[5m]` — range vector (values over last 5 minutes)
- `rate(http_requests_total[5m])` — per-second rate over 5 minutes
- `sum by (service) (rate(...))` — aggregate by label

Example: average request latency per service:
```promql
histogram_quantile(0.95,
  sum by (le, service) (
    rate(http_server_requests_seconds_bucket[5m])
  )
)
```

---

**Q: What is Grafana provisioning and why use it?**

Provisioning lets you configure Grafana via YAML and JSON files at startup instead of clicking through the UI. Without provisioning, configuration is lost when the container restarts. With provisioning, the entire Grafana setup is in version control and reproducible. Key files: `datasources.yml` (which data sources to connect to), `dashboards.yml` (where to find dashboard JSON files), and the dashboard JSON files themselves.

---

**Q: What is an ELK/EFK stack?**

ELK: Elasticsearch (storage + search), Logstash (log processing), Kibana (UI). EFK replaces Logstash with Filebeat, which is lighter weight and better suited for log collection without complex transformations. Filebeat reads log files and ships them to Elasticsearch. Kibana provides search, filtering, and visualization of logs stored in Elasticsearch.

---

**Q: Why does Filebeat run as a DaemonSet in Kubernetes?**

Container logs in K8s are stored as files on the node where the container runs. A DaemonSet ensures exactly one Filebeat pod runs on each node, giving it access to that node's log files via hostPath volumes. If Filebeat ran as a regular Deployment with 1 replica, it could only collect logs from the node it's scheduled on, missing logs from all other nodes.

---

**Q: What is RBAC in Kubernetes and why does Filebeat need it?**

RBAC (Role-Based Access Control) controls what Kubernetes API resources each identity can access. Filebeat uses `add_kubernetes_metadata` to enrich logs with pod information (labels, namespace, pod name). To do this, it queries the K8s API (`/api/v1/pods`, `/api/v1/namespaces`). Without a ClusterRole granting `get/list/watch` on pods and namespaces, these API calls fail and logs have no K8s metadata.

---

**Q: What is the difference between a ConfigMap and a Secret in Kubernetes?**

ConfigMap stores non-sensitive configuration — URLs, feature flags, config files. Secret stores sensitive data — passwords, tokens, certificates. Both can be mounted as volumes or injected as env vars. Secrets are base64-encoded (not encrypted) in etcd by default. For real security, use Sealed Secrets or External Secrets Operator to store encrypted values in Git or AWS SSM/Vault.

---

**Q: What is a Helm hook and when would you use it?**

A Helm hook is a manifest with a special annotation that makes it run at a specific point in the release lifecycle (pre-install, post-install, pre-upgrade, post-upgrade, etc.). Common use cases: running database migrations after deploy, creating initial data (like the Kibana data view setup), waiting for dependencies before proceeding. The `hook-delete-policy` controls cleanup — `hook-succeeded` deletes the Job after it completes successfully.

---

**Q: What is `vm.max_map_count` and why does Elasticsearch need it?**

`vm.max_map_count` is a Linux kernel parameter that limits the number of memory-mapped areas a process can have. Elasticsearch uses memory-mapped files for its Lucene indices. The default value (65530) is too low — ES needs at least 262144. In K8s, this is set via a privileged initContainer running `sysctl -w vm.max_map_count=262144` before the main Elasticsearch container starts.

---

**Q: How does nginx ingress sub-path routing work?**

The nginx ingress rewrite annotation `nginx.ingress.kubernetes.io/rewrite-target: /$2` uses regex capture groups in the path. The path `/grafana(/|$)(.*)` captures everything after `/grafana/` into `$2`. nginx rewrites the URL to just `/$2` before forwarding to Grafana — effectively stripping the `/grafana` prefix. However, the application itself must also know it's at a subpath (via `GF_SERVER_SERVE_FROM_SUB_PATH=true` for Grafana, `SERVER_BASEPATH=/kibana` for Kibana) otherwise internal links it generates will be broken.

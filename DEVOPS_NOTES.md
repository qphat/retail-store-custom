# DevOps Notes — Retail Store Sample App

A full walkthrough of everything built, why each decision was made, and what you'd say in an interview.

---

## 1. Dockerfile — Multi-Stage Builds

### What is a multi-stage build?

A Dockerfile with more than one `FROM` instruction. Each stage is independent. You copy only what you need from one stage to the next.

```dockerfile
FROM golang:1.24-alpine AS build-env   # Stage 1: build
...
FROM alpine:3.20                        # Stage 2: run
COPY --from=build-env /app/main .
```

### Why do this?

The build stage needs compilers, build tools, source code — all large. The run stage needs only the compiled binary. Without multi-stage:
- Go image = ~300MB
- With multi-stage final image = ~15MB

**Interview answer:** "Multi-stage builds separate build-time dependencies from runtime dependencies, producing a smaller, more secure final image with a reduced attack surface."

---

## 2. Dockerfile — Base Image Choices

### catalog (Go) — `golang:1.24-alpine` → `alpine:3.20`

- Alpine is ~5MB. Tiny, minimal attack surface.
- Go compiles to a static binary — needs almost nothing to run.
- **Why not scratch?** The app uses CGO (sqlite3), which requires libc. Alpine has musl libc.

### cart, orders, ui (Java) — `maven:3.9-eclipse-temurin-21` → `eclipse-temurin:21-jre-jammy`

- Build stage: Maven image has JDK + Maven. Heavy but only used to compile.
- Run stage: JRE only (no compiler), Ubuntu Jammy (22.04).
- **Why not Alpine for Java?** Alpine uses musl libc. JVM was designed for glibc (Linux standard). musl causes subtle bugs — DNS resolution issues, GC problems, random crashes. Jammy uses glibc, stable for JVM.
- **Why JRE not JDK?** JRE = runtime only. JDK includes compiler, debugger, javadoc — not needed at runtime. Smaller image, less attack surface.

### checkout (Node) — `node:22-alpine` → `node:22-alpine`

- Same image for both stages because Node/Alpine is already small (~50MB).
- No need to switch to a smaller base.
- **Why Alpine here but not Java?** Node.js is not as sensitive to musl libc as the JVM.

---

## 3. Dockerfile — Layer Caching

### The pattern

```dockerfile
COPY go.mod go.sum ./      # copy dependency files first
RUN go mod download        # download deps (cached layer)
COPY . .                   # copy source code
RUN go build ...           # build (only re-runs when source changes)
```

### Why this order?

Docker caches each layer. If a layer's input hasn't changed, Docker reuses the cache. Source code changes frequently. Dependencies change rarely.

If you did `COPY . .` first, every source code change would invalidate the dependency download cache, forcing a full re-download every build.

**Interview answer:** "Copy dependency manifests first and install dependencies before copying source code, so the expensive dependency download step is cached and only re-runs when dependencies actually change."

---

## 4. Dockerfile — Security

### Non-root user

```dockerfile
RUN groupadd -g 1000 appgroup && useradd -u 1000 -g appgroup -m appuser
USER appuser
```

**Why?** Containers run as root by default. If an attacker exploits your app, they get root inside the container. Running as a non-root user limits the blast radius.

**Why UID 1000?** Convention. First non-root user on Linux systems. Avoids conflicts with system users (UIDs 0-999).

**Why not the node image's built-in `node` user for Java?** The `node` user only exists in Node images. Java images don't have it.

### `cap_drop: all` in docker-compose

```yaml
cap_drop:
  - all
```

Linux capabilities are fine-grained root privileges. By default containers get some (e.g., `NET_BIND_SERVICE`). Dropping all removes every privilege the container doesn't need.

### `no-new-privileges`

```yaml
security_opt:
  - no-new-privileges:true
```

Prevents the process inside the container from gaining more privileges via setuid binaries (e.g., `sudo`).

### Read-only volume mounts `:ro`

```yaml
- ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
```

Container can read the config but can't modify it. If compromised, attacker can't alter config files.

---

## 5. Dockerfile — JVM Tuning

```dockerfile
ENV JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError"
```

### Why `JAVA_TOOL_OPTIONS` not `ENTRYPOINT ["java", "-XX:...", "-jar", ...]`?

`JAVA_TOOL_OPTIONS` is read by the JVM automatically from the environment. No need to touch ENTRYPOINT. Cleaner, and works even if someone overrides ENTRYPOINT.

### `-XX:+UseContainerSupport`

Without this, the JVM reads host memory/CPU instead of the container's cgroup limits. A container with 512MB limit on a 32GB host would think it has 32GB and allocate too much heap, causing OOM kills.

### `-XX:MaxRAMPercentage=75.0`

Heap = 75% of container memory limit. Leaves 25% for:
- JVM metaspace (class metadata)
- Thread stacks
- Native memory

### `-XX:+UseG1GC`

G1 (Garbage First) GC. Best general-purpose GC for services — low pause times, good throughput. Default in Java 9+ but explicit is better.

### `-XX:+ExitOnOutOfMemoryError`

JVM crashes immediately on OOM instead of hanging. The orchestrator (Docker, Kubernetes) restarts the container. Hanging is worse — the app is broken but looks alive.

---

## 6. Dockerfile — ENTRYPOINT vs CMD vs shell form

### exec form vs shell form

```dockerfile
# Shell form — BAD for PID 1
ENTRYPOINT ["sh", "-c", "java -jar app.jar"]

# Exec form — GOOD
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Shell form spawns `sh` as PID 1. When Docker sends `SIGTERM` on `docker stop`, `sh` receives it but doesn't forward it to the Java process. Java never gets the signal, doesn't shut down gracefully, Docker force-kills after 10s.

Exec form makes `java` PID 1 directly. Receives signals, shuts down gracefully.

---

## 7. Docker Compose — depends_on with healthcheck

```yaml
depends_on:
  mysql:
    condition: service_healthy
    restart: true
```

### Why `condition: service_healthy` not just `depends_on: mysql`?

Plain `depends_on` waits for the container to **start**, not to be **ready**. MySQL takes 20-30s to initialize after the container starts. Without the healthcheck condition, the app starts while MySQL is still initializing, connection fails, app crashes.

### Why `restart: true`?

If the dependency becomes unhealthy later (DB crashes), restart this service too.

---

## 8. Docker Compose — Resource Limits

```yaml
deploy:
  resources:
    limits:
      cpus: "0.5"
      memory: 512M
    reservations:
      cpus: "0.1"
      memory: 256M
```

### limits vs reservations

- **limits** — hard ceiling. Container is throttled (CPU) or killed (memory) if exceeded.
- **reservations** — guaranteed minimum. Docker won't schedule the container if the host can't provide this.

### Why does this matter?

Without limits, one runaway container can consume all host resources and starve everything else. With limits, each service gets a fair share.

### Why 512M for Java, 256M for Node, 128M for Go?

- Java JVM has overhead beyond heap: metaspace, thread stacks, JIT compiled code. 512M gives enough room.
- Node.js is lighter, 256M is sufficient.
- Go compiles to a small static binary with very low memory overhead.

---

## 9. Docker Compose — hostname removed

We removed `hostname: cart` because:

Setting `hostname: cart` makes the container's own hostname `cart`. Spring Boot / Log4j tries to resolve the hostname via DNS on startup. Docker's internal DNS doesn't have an entry for the container's own hostname, so DNS resolution fails and the app crashes.

Docker Compose already gives each service a DNS name equal to the service name (e.g., `cart`) for **other services** to reach it. You don't need to set `hostname` for that.

---

## 10. Observability — Prometheus (Metrics)

### Pull model

Prometheus scrapes your app's `/metrics` endpoint on a schedule. Your app doesn't send data to Prometheus — Prometheus comes to fetch it.

```
prometheus → GET catalog:8080/metrics → every 15s
```

### Why pull not push?

- Prometheus controls the rate. No thundering herd of apps all pushing at once.
- Easy to detect when a service is down (scrape fails).
- No extra code in the app to push — just expose an endpoint.

### Different metrics paths

```yaml
# Go (catalog, checkout)
metrics_path: /metrics

# Java Spring Boot (cart, orders, ui)
metrics_path: /actuator/prometheus
```

Spring Boot Actuator serves metrics at `/actuator/prometheus`. Go and Node serve at `/metrics` by convention.

---

## 11. Observability — Grafana Dashboards as Code

### Why not import manually?

Manual import means:
- Every new team member has to do it.
- Dashboards aren't version controlled.
- Reproducing the environment from scratch loses all dashboards.

### How provisioning works

Grafana reads from `/etc/grafana/provisioning/` on startup:
- `datasources/` — auto-configures data sources
- `dashboards/` — auto-loads dashboard JSON files

Mount your local files there via Docker volumes.

### Fixed datasource UID

```yaml
# datasources.yml
uid: PBFA97CFB590B2093
```

Dashboard JSON files reference datasources by UID. If you don't pin the UID, Grafana generates a random one each startup. Dashboard JSONs that reference a specific UID show no data.

Pinning the UID makes datasource and dashboard consistent across environments.

---

## 12. Observability — ELK Stack (Logs)

### Why separate tools for logs vs metrics?

Metrics are numbers — small, structured, easy to store as time-series. Prometheus is optimized for this.

Logs are text — large, unstructured, need full-text search. Elasticsearch is optimized for this. You can't efficiently store millions of log lines in Prometheus, and you can't do time-series math on logs in Elasticsearch.

### Why Filebeat not direct logging to Elasticsearch?

Your app logs to stdout. Docker captures stdout to log files. Filebeat tails those files and ships to Elasticsearch.

The alternative (logging directly from app to Elasticsearch) couples your app to your logging infrastructure. If Elasticsearch is down, your app blocks. Filebeat buffers and retries — your app is unaffected.

### Why `--strict.perms=false`?

Filebeat requires its config file to be owned by root (security feature — prevents non-root users from injecting malicious config). The file is owned by your host user (`koomi`), not root. `--strict.perms=false` skips this check for local dev.

**Never use this in production** — in prod, the config file would be managed by a configuration management tool (Ansible, Puppet) and owned by root.

### Kibana Data View as code

```yaml
kibana-setup:
  image: curlimages/curl:latest
  restart: on-failure
  command: >
    curl -X POST http://kibana:5601/api/data_views/data_view ...
```

A one-shot container that calls Kibana's API to create the Data View. `restart: on-failure` retries if Kibana isn't ready yet, stops permanently once it succeeds (exit 0).

**Why not manual?** Same reason as Grafana dashboards — reproducibility, version control, no manual steps for new team members.

---

## Interview Questions You Should Be Able to Answer

**Q: Why use multi-stage Docker builds?**
Separate build tools from runtime. Smaller final image, reduced attack surface.

**Q: Why not run containers as root?**
If the app is compromised, attacker gets root inside the container. Non-root limits the blast radius.

**Q: Why does Java need special base image consideration?**
JVM requires glibc. Alpine uses musl libc which causes subtle JVM issues. Use Debian/Ubuntu-based images for Java.

**Q: What's the difference between ENTRYPOINT exec form and shell form?**
Shell form spawns sh as PID 1, which doesn't forward signals. Exec form makes the app PID 1, receives SIGTERM correctly, enables graceful shutdown.

**Q: Why does layer order matter in Dockerfiles?**
Docker caches layers. Copy dependency files before source code so the dependency install layer is cached and doesn't re-run on every source change.

**Q: What's the difference between Prometheus and ELK?**
Prometheus = metrics (numbers over time). ELK = logs (text events). Different data types, different query patterns, different storage engines.

**Q: Why use Filebeat instead of logging directly to Elasticsearch?**
Decoupling. App logs to stdout, Filebeat ships asynchronously. App is unaffected by Elasticsearch downtime.

**Q: What does `UseContainerSupport` do in JVM?**
Makes JVM read memory/CPU limits from cgroup (container limits) instead of host resources.

**Q: Why pin datasource UIDs in Grafana provisioning?**
Dashboard JSON references datasource by UID. Random UIDs break the reference. Pinning ensures consistency.

---

## More Interview Questions

### Docker & Containers

**Q: What is a Docker image vs a Docker container?**
Image = read-only template (like a class). Container = running instance of an image (like an object). Multiple containers can run from the same image.

**Q: What is a Docker layer?**
Each instruction in a Dockerfile creates a read-only layer. Layers are stacked — the final image is all layers combined. Layers are cached and shared between images, saving disk space and build time.

**Q: What happens when you run `docker stop`?**
Docker sends `SIGTERM` to PID 1 inside the container. Waits 10 seconds (grace period). If still running, sends `SIGKILL` (force kill). Your app should handle `SIGTERM` to close DB connections, finish in-flight requests, then exit cleanly.

**Q: What is the difference between `COPY` and `ADD` in Dockerfile?**
`COPY` just copies files. `ADD` also extracts tar archives and can fetch from URLs. Always prefer `COPY` — `ADD` has surprising behavior that makes Dockerfiles harder to understand.

**Q: What is `.dockerignore`?**
Like `.gitignore` for Docker. Tells Docker which files to exclude from the build context. Without it, Docker sends everything (including `node_modules`, `.git`, build artifacts) to the Docker daemon, slowing down every build.

**Q: What is the difference between `docker-compose up` and `docker-compose run`?**
`up` starts all services defined in the file and keeps them running. `run` starts a one-off container for a specific service (e.g., run a migration or a test), then stops it.

**Q: How do containers communicate with each other in Docker Compose?**
Docker Compose creates a shared network for all services in the file. Each service is reachable by its service name as a DNS hostname. `catalog` can reach `orders` at `http://orders:8080` because Docker's internal DNS resolves service names.

**Q: What is the difference between a volume and a bind mount?**
- **Volume** — managed by Docker, stored in `/var/lib/docker/volumes/`. Portable, works on any OS.
- **Bind mount** — maps a specific host path into the container (e.g., `./config:/etc/config`). Depends on host directory structure. Used for config files and local development.

**Q: Why is `restart: always` used in production but not always in development?**
`restart: always` restarts the container on any exit including manual `docker stop`. In development this is annoying — you stop a container intentionally and it restarts. Use `restart: on-failure` for dev (only restart on crash) or `restart: always` for prod (always keep it running).

**Q: What is the difference between `CMD` and `ENTRYPOINT`?**
- `ENTRYPOINT` — the main executable. Hard to override.
- `CMD` — default arguments to `ENTRYPOINT`. Easily overridden at runtime.
- Together: `ENTRYPOINT ["java"]` + `CMD ["-jar", "app.jar"]` → `java -jar app.jar`. Override CMD with `docker run myimage -jar other.jar`.

**Q: How would you reduce Docker image size?**
1. Multi-stage builds — don't include build tools in final image.
2. Use Alpine or slim base images.
3. Combine RUN commands with `&&` to avoid extra layers.
4. Clean package manager caches in the same RUN step (`rm -rf /var/lib/apt/lists/*`).
5. Use `.dockerignore` to exclude unnecessary files.

**Q: What does `cap_drop: all` do and why?**
Removes all Linux capabilities from the container. Capabilities are fine-grained privileges (bind ports below 1024, load kernel modules, etc.). Dropping all follows the principle of least privilege — the container gets only what it explicitly needs.

---

### Observability

**Q: What are the three pillars of observability?**
- **Metrics** — numbers over time (CPU, request rate, error rate). Tells you something is wrong.
- **Logs** — text events with context. Tells you what happened.
- **Traces** — follow a single request across multiple services. Tells you where time was spent.

**Q: What is the difference between monitoring and observability?**
Monitoring = watching known failure modes (is the service up? is CPU above 90%?). Observability = being able to ask arbitrary questions about system behavior from its outputs. Observability includes monitoring but goes further.

**Q: What is a Prometheus metric type?**
- **Counter** — only goes up (total requests, total errors). Reset on restart.
- **Gauge** — goes up and down (current memory, active connections).
- **Histogram** — samples observations into buckets (request duration distribution).
- **Summary** — similar to histogram but calculates quantiles client-side.

**Q: What is PromQL? Give an example.**
Prometheus Query Language. Used to query metrics.
```
# Request rate per second over last 5 minutes
rate(http_requests_total[5m])

# 99th percentile latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# Error rate
rate(http_requests_total{status="500"}[5m]) / rate(http_requests_total[5m])
```

**Q: What is the difference between a log shipper and a log aggregator?**
- **Shipper** (Filebeat, Fluentd) — runs close to the source, reads logs, forwards them. Lightweight.
- **Aggregator** (Logstash, Elasticsearch) — receives from multiple shippers, processes, stores. Heavy.

**Q: What is an Elasticsearch index?**
Like a database table. All documents (log lines) in an index share the same schema. We create one index per service per day (`logs-catalog-2026.04.04`) so you can delete old data easily by dropping old indexes.

**Q: What is Kibana used for?**
Search and visualize data stored in Elasticsearch. Discover = raw log search. Dashboard = visualizations. Alerts = notify when conditions are met (e.g., error rate spike).

**Q: What is the difference between `scrape_interval` and `evaluation_interval` in Prometheus?**
- `scrape_interval` — how often Prometheus fetches metrics from targets.
- `evaluation_interval` — how often Prometheus evaluates alerting rules.
Both default to 15s. Keep them the same to avoid missing data in alerts.

**Q: Why log to stdout/stderr instead of log files?**
Containers are ephemeral — they can be killed and replaced. Log files inside a container are lost when it's removed. stdout/stderr is captured by Docker (or Kubernetes) and can be shipped to a centralized system. It's also simpler — no log rotation, no disk management inside the container.

---

### General DevOps

**Q: What is the 12-factor app methodology as it relates to containers?**
A set of principles for building portable, scalable apps. Most relevant to containers:
- **Config via environment variables** — not hardcoded, not config files in the image.
- **Logs as event streams** — write to stdout, let the platform handle collection.
- **Stateless processes** — don't store state in the container. Use external DBs, caches.
- **Disposability** — fast startup, graceful shutdown. Containers are killed and replaced constantly.

**Q: What is the difference between horizontal and vertical scaling?**
- **Vertical** — bigger machine (more CPU, more RAM). Limited by hardware ceiling.
- **Horizontal** — more instances. Scales to any size but requires stateless apps and a load balancer.
Containers are designed for horizontal scaling.

**Q: What is a health check and why does it matter?**
A command that reports whether a service is healthy. Docker/Kubernetes uses it to:
- Hold traffic until the app is ready (readiness).
- Restart the container if it becomes unhealthy (liveness).
Without health checks, a broken app keeps receiving traffic because the container is "running" even if the app inside is crashed.

**Q: What is the difference between a liveness probe and a readiness probe? (Kubernetes concept)**
- **Liveness** — is the app alive? If not, restart the container.
- **Readiness** — is the app ready to receive traffic? If not, remove from load balancer but don't restart.
Example: app is alive (liveness ok) but still warming up cache (readiness not ok). Don't send traffic yet, but don't restart.

**Q: What is infrastructure as code (IaC)?**
Managing infrastructure (servers, networks, databases) through code files instead of manual clicks in a console. Benefits: version controlled, reproducible, reviewable, automatable. Tools: Terraform, CloudFormation, Pulumi.

**Q: What is the principle of least privilege?**
Give every process/user/service only the permissions it needs to do its job, nothing more. Applied throughout our setup: non-root users, `cap_drop: all`, read-only volume mounts, no-new-privileges.

**Q: What is a container registry?**
A storage system for Docker images. Like GitHub for code but for container images. Examples: Docker Hub, AWS ECR, Google GCR. You push images to a registry, then Kubernetes/ECS pulls from it to run containers.

**Q: What is the difference between Docker and Kubernetes?**
- **Docker** — runs containers on a single machine.
- **Kubernetes** — orchestrates containers across a cluster of machines. Handles scheduling, scaling, self-healing, load balancing, rolling updates. Docker is the runtime; Kubernetes is the orchestrator.

**Q: What is a sidecar container?**
A helper container that runs alongside the main app container in the same pod (Kubernetes) or task (ECS). Examples: Filebeat as a sidecar to ship logs, Envoy proxy as a sidecar for service mesh, a metrics exporter sidecar. They share network and can share volumes with the main container.

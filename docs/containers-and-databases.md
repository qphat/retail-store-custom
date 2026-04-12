# Containers & Databases — DevOps Reference

> How containers and pods work with databases: patterns, pitfalls, migrations, secrets, and interview answers.

---

## Table of Contents

1. [Core Rule — Never Run Production DB in a Container](#1-core-rule)
2. [How Containers Connect to a Database](#2-how-containers-connect-to-a-database)
3. [Connection Pooling](#3-connection-pooling)
4. [DB Migrations — The Hard Part](#4-db-migrations)
5. [Zero-Downtime Migration Pattern (Expand-Contract)](#5-zero-downtime-migration-pattern)
6. [Secrets Management](#6-secrets-management)
7. [Stateful vs Stateless Containers](#7-stateful-vs-stateless-containers)
8. [ECS-Specific Patterns](#8-ecs-specific-patterns)
9. [Kubernetes-Specific Patterns](#9-kubernetes-specific-patterns)
10. [This Project's DB Strategy](#10-this-projects-db-strategy)
11. [Interview Q&A](#11-interview-qa)

---

## 1. Core Rule

### Never run a production database in a container

Containers are **ephemeral** — they are designed to be killed and restarted at any time.

```
Container restart  →  all data inside is wiped
Pod eviction       →  all data inside is wiped
Node failure       →  all data inside is wiped
```

| Environment | DB in container? | Why |
|---|---|---|
| Local dev | OK | Data loss is acceptable, convenience matters |
| CI/CD integration tests | OK | Throwaway DB, fresh per run |
| Staging | Avoid | Use managed DB (match prod) |
| Production | Never | Data loss is catastrophic |

### The right mental model

```
Stateless (containers):   App code, web servers, APIs
                          → Scale freely, kill/restart anytime

Stateful (managed):       Databases, message queues, caches
                          → Use AWS RDS, DynamoDB, ElastiCache, RabbitMQ
```

---

## 2. How Containers Connect to a Database

The container never "contains" the database — it just knows the address.

### Basic pattern

```
Container/Pod
  ├── reads env var: DB_HOST=mydb.abc123.us-east-1.rds.amazonaws.com
  ├── reads env var: DB_PORT=5432
  ├── reads env var: DB_NAME=orders
  ├── reads env var: DB_USER=app
  └── reads env var: DB_PASSWORD=*** (from secrets manager)
        │
        │  TCP connection
        ▼
  RDS PostgreSQL (outside the container, in the VPC)
```

### Where env vars come from

**docker-compose (local dev):**
```yaml
services:
  orders:
    image: orders:latest
    environment:
      DB_HOST: postgres     # docker-compose service name = hostname
      DB_PORT: 5432
      DB_NAME: orders
      DB_USER: app
      DB_PASSWORD: devpassword  # plaintext OK for local only
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: orders
      POSTGRES_USER: app
      POSTGRES_PASSWORD: devpassword
```

**ECS Task Definition:**
```hcl
# In Terraform — env vars injected at task start
environment = [
  { name = "DB_HOST", value = "mydb.abc123.us-east-1.rds.amazonaws.com" },
  { name = "DB_PORT", value = "5432" },
]
secrets = [
  # Pulled from SSM Parameter Store at task start — never stored in task def
  { name = "DB_PASSWORD", valueFrom = "arn:aws:ssm:us-east-1:123:parameter/dev/orders/db-password" },
]
```

**Kubernetes:**
```yaml
# Secret (base64 encoded — NOT encrypted by default)
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  password: bXlwYXNzd29yZA==   # base64("mypassword")

---
# Pod uses the secret
spec:
  containers:
    - name: orders
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
```

---

## 3. Connection Pooling

### The problem

```
10 pods × 10 connections per pod = 100 connections to RDS
100 pods × 10 connections per pod = 1000 connections to RDS

RDS db.t3.micro max_connections = 66
RDS db.t3.small max_connections = 150

→ You hit the limit → new connections refused → app crashes
```

This is one of the most common production incidents when scaling containerized apps.

### Fix 1: App-level connection pool (always do this)

Every app should set a max pool size per instance:

```go
// Go (catalog service)
db.SetMaxOpenConns(10)    // max 10 connections per pod
db.SetMaxIdleConns(5)
db.SetConnMaxLifetime(5 * time.Minute)
```

```java
// Spring Boot / HikariCP (orders service)
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.minimum-idle=2
```

```javascript
// Node.js (checkout service)
const pool = new Pool({ max: 10 });
```

### Fix 2: Connection pooler (for high pod counts)

```
Pods (100)  →  PgBouncer / RDS Proxy  →  RDS

PgBouncer pools connections:
  100 pods × 10 app connections = 1000 app-side connections
  PgBouncer → RDS: only 50 real DB connections
```

| Option | Where it runs | Best for |
|---|---|---|
| **PgBouncer** | Sidecar container or separate service | K8s, self-managed |
| **RDS Proxy** | AWS managed, in VPC | ECS/EKS on AWS |
| **pgpool-II** | Separate service | PostgreSQL only, advanced routing |

**RDS Proxy in Terraform:**
```hcl
resource "aws_db_proxy" "orders" {
  name                   = "dev-orders-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db_password.arn
  }
}
```

App connects to proxy endpoint instead of RDS endpoint directly.

### Fix 3: Scale RDS instance class

As a last resort — but pooling is always better.

---

## 4. DB Migrations

This is where most teams make mistakes. Three questions to answer:

1. **Who runs the migration?**
2. **When does it run?**
3. **What if old and new app versions run at the same time?**

### Who runs migrations?

#### Option A: Init Container / One-off Task (Recommended)

Run migration before app starts. App container waits.

```
K8s:   initContainer: migrate → (exits 0) → app container starts
ECS:   run-task --overrides=migrate → (wait for exit 0) → update service
```

**K8s init container:**
```yaml
spec:
  initContainers:
    - name: migrate
      image: orders:latest
      command: ["./migrate", "up"]    # or: java -jar app.jar --migrate-only
      env:
        - name: DB_HOST
          value: "mydb.abc123.rds.amazonaws.com"
  containers:
    - name: orders
      image: orders:latest
```

The `initContainer` runs first. If it fails (non-zero exit), the main container never starts. This prevents a broken migration from crashing the app.

**ECS one-off task (in CI/CD pipeline):**
```bash
# In GitHub Actions, before deploying the service
TASK_ARN=$(aws ecs run-task \
  --cluster dev-retail-store \
  --task-definition dev-orders-migrate \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[...],securityGroups=[...]}" \
  --overrides '{"containerOverrides":[{"name":"orders","command":["./migrate","up"]}]}' \
  --query 'tasks[0].taskArn' --output text)

# Wait for migration to complete
aws ecs wait tasks-stopped --cluster dev-retail-store --tasks $TASK_ARN

# Check exit code
EXIT=$(aws ecs describe-tasks \
  --cluster dev-retail-store \
  --tasks $TASK_ARN \
  --query 'tasks[0].containers[0].exitCode' --output text)

[ "$EXIT" = "0" ] || { echo "Migration failed"; exit 1; }
```

#### Option B: Separate CI/CD Step (Also Good)

Run migration as a pipeline step before deploying the new app version.

```yaml
# In GitHub Actions
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - name: Run DB migration
        run: |
          # Run migration task
          aws ecs run-task ...

  deploy:
    needs: migrate    # deploy only after migration succeeds
    runs-on: ubuntu-latest
    steps:
      - name: Deploy app
        run: ...
```

#### Option C: App runs migration on startup (Dangerous)

```java
// Spring Boot — Flyway/Liquibase auto-runs on startup
spring.flyway.enabled=true
```

**Why this is risky with containers:**

```
Deploy starts: 3 old pods running + 3 new pods starting
               ↓
New pod 1 starts: runs migration → ALTER TABLE orders ADD COLUMN new_field
New pod 2 starts: runs migration simultaneously → DEADLOCK or DUPLICATE COLUMN ERROR
New pod 3 starts: same issue

Old pods:      still running, now reading a schema they don't understand
```

If you use this approach (many teams do), use a migration library that handles distributed locking:
- **Flyway** — uses `flyway_schema_history` table with row locking
- **Liquibase** — uses `DATABASECHANGELOGLOCK` table

But it's still safer to run migrations as a separate step.

### Choosing the right tool

| Language | Migration tool |
|---|---|
| Go | `golang-migrate/migrate`, `goose` |
| Java | Flyway (Spring Boot default), Liquibase |
| Node.js | `db-migrate`, `knex` migrations, `prisma migrate` |
| Python | Alembic (SQLAlchemy), Django migrations |

---

## 5. Zero-Downtime Migration Pattern

### The problem

During a rolling deployment, **old and new versions of your app run simultaneously**.

```
Deploy new version:
  t=0:  3 old pods running (v1)
  t=30: 2 old pods + 1 new pod (v1 + v2)
  t=60: 1 old pod + 2 new pods (v1 + v2)
  t=90: 3 new pods running (v2)
```

If your migration is not backwards-compatible, old pods (v1) will break when v2's migration runs.

### The Expand-Contract Pattern (3-deploy strategy)

Never make a breaking schema change in a single deploy. Always split into 3 steps.

#### Example: Rename column `user_name` → `full_name`

**Wrong (breaks during deploy):**
```sql
-- Migration in single deploy: renames column
ALTER TABLE users RENAME COLUMN user_name TO full_name;
```
Old pods (v1) still query `user_name` → column not found → crash.

**Right (3 deploys):**

**Deploy 1 — Expand (add new, keep old):**
```sql
-- Add new column
ALTER TABLE users ADD COLUMN full_name VARCHAR(255);

-- Copy existing data
UPDATE users SET full_name = user_name;

-- Make new column non-null (after copy)
ALTER TABLE users ALTER COLUMN full_name SET NOT NULL;
```
App v1: reads `user_name` → works.
App v2: reads `full_name` → works (both columns exist).

**Deploy 2 — Migrate app code:**
```go
// v2 code: write to BOTH columns during transition
user.UserName = name   // keep writing old column (for v1 pods still running)
user.FullName = name   // start writing new column
```

Wait until all v1 pods are gone. Now only v2 pods run.

**Deploy 3 — Contract (drop old):**
```sql
-- Now safe to drop — no more v1 pods
ALTER TABLE users DROP COLUMN user_name;
```
App v3: only reads `full_name`.

### Rules for backwards-compatible migrations

| Operation | Safe? | Notes |
|---|---|---|
| Add nullable column | Safe | Old code ignores it |
| Add column with default | Safe | Old code ignores it |
| Add NOT NULL column | Unsafe | Old code doesn't write it → constraint fails |
| Add index | Safe (non-blocking) | Use `CREATE INDEX CONCURRENTLY` in PostgreSQL |
| Drop column | Unsafe | Old code still reads it |
| Rename column | Unsafe | Use expand-contract |
| Change column type | Unsafe | Add new column, migrate, drop old |
| Add table | Safe | Old code ignores it |
| Drop table | Unsafe | Old code still uses it |

---

## 6. Secrets Management

### Never do this

```yaml
# docker-compose.yml — committed to Git
environment:
  DB_PASSWORD: mypassword123    # now in Git history forever

# k8s deployment.yaml — committed to Git
env:
  - name: DB_PASSWORD
    value: "mypassword123"      # same problem
```

### Kubernetes Secrets (base64, not encrypted)

```bash
# Create
kubectl create secret generic db-secret \
  --from-literal=password=mypassword

# What it looks like in YAML
data:
  password: bXlwYXNzd29yZA==   # just base64, anyone with kubectl can decode

echo "bXlwYXNzd29yZA==" | base64 -d
# → mypassword
```

K8s Secrets are base64, not encrypted. By default, etcd stores them in plaintext. To actually encrypt: enable Secrets Encryption at Rest in the control plane config.

### Better: External Secrets Operator (K8s)

Syncs secrets FROM AWS SSM/Secrets Manager INTO K8s Secrets automatically.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-password
spec:
  secretStoreRef:
    name: aws-parameter-store
    kind: SecretStore
  target:
    name: db-secret       # creates this K8s Secret
  data:
    - secretKey: password
      remoteRef:
        key: /dev/orders/db-password   # SSM parameter path
```

App reads from K8s Secret (normal) — but the source of truth is AWS SSM. Rotation in SSM automatically syncs to K8s.

### ECS: SSM Parameter Store (recommended)

```hcl
# Terraform: store secret in SSM
resource "aws_ssm_parameter" "db_password" {
  name  = "/dev/orders/db-password"
  type  = "SecureString"   # KMS encrypted at rest
  value = var.db_password
}

# Task definition: pull at task start
secrets = [
  {
    name      = "DB_PASSWORD"
    valueFrom = aws_ssm_parameter.db_password.arn
  }
]
```

The execution role needs permission:
```hcl
resource "aws_iam_role_policy" "execution_ssm" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:*:*:parameter/dev/*"
    }]
  })
}
```

### Comparison

| Method | Encrypted at rest | In Git? | Rotation | Best for |
|---|---|---|---|---|
| Plaintext in yaml | No | Yes (bad) | Manual | Never |
| K8s Secret | Maybe (need config) | No | Manual | Simple cases |
| External Secrets Operator | Yes (AWS KMS) | No | Automatic | K8s + AWS |
| ECS SSM SecureString | Yes (AWS KMS) | No | Manual | ECS |
| ECS Secrets Manager | Yes (AWS KMS) | No | Automatic | ECS, needs rotation |
| HashiCorp Vault | Yes | No | Automatic | Multi-cloud, advanced |

---

## 7. Stateful vs Stateless Containers

### Stateless containers (app code)

```
Characteristics:
  - No important data stored inside the container
  - Any instance can handle any request
  - Kill/restart anytime without data loss
  - Scale horizontally freely

Examples: catalog, cart, orders, checkout, ui services
```

### Stateful containers (databases)

```
Characteristics:
  - Data lives inside (or must be persisted)
  - Needs a stable identity/hostname (Pod A ≠ Pod B)
  - Cannot be killed without care
  - Scaling is complex

Examples: PostgreSQL, MySQL, Redis, Elasticsearch, MongoDB
```

### Running DB in Kubernetes (when you must — dev/learning)

Use **StatefulSet** + **PersistentVolumeClaim**, not Deployment.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres    # stable DNS: postgres-0.postgres.default.svc
  replicas: 1
  template:
    spec:
      containers:
        - name: postgres
          image: postgres:15
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:    # PVC auto-created per replica
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 10Gi
```

**StatefulSet vs Deployment:**
| Feature | Deployment | StatefulSet |
|---|---|---|
| Pod names | random (pod-abc123) | stable (postgres-0, postgres-1) |
| DNS | random | stable (postgres-0.postgres.svc) |
| Volume | shared or none | dedicated PVC per pod |
| Use for | stateless apps | databases, Kafka, ZooKeeper |

---

## 8. ECS-Specific Patterns

### Secrets via SSM (task definition)

```hcl
container_definitions = jsonencode([{
  name  = "orders"
  image = "koomi1/retail-app-orders:latest"

  environment = [
    { name = "DB_HOST", value = "mydb.abc123.us-east-1.rds.amazonaws.com" },
    { name = "DB_PORT", value = "5432" },
  ]

  secrets = [
    # Pulled from SSM at task start — never visible in ECS console
    { name = "DB_PASSWORD", valueFrom = "/dev/orders/db-password" },
    { name = "DB_USER",     valueFrom = "/dev/orders/db-user"     },
  ]
}])
```

### IAM Task Role (for DynamoDB/S3 — no credentials needed)

```hcl
resource "aws_iam_role" "task" {
  name = "dev-cart-task-role"
  assume_role_policy = jsonencode({
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "dynamodb" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:Query"]
      Resource = "arn:aws:dynamodb:us-east-1:*:table/dev-cart"
    }]
  })
}
```

The cart container calls DynamoDB using the task role — no `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` needed.

### DB migration via ECS run-task

```bash
# Run migration as one-off task before deploying the service
aws ecs run-task \
  --cluster dev-retail-store \
  --task-definition dev-orders \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[subnet-xxx],
    securityGroups=[sg-xxx],
    assignPublicIp=DISABLED
  }" \
  --overrides '{
    "containerOverrides": [{
      "name": "orders",
      "command": ["java", "-jar", "app.jar", "--migrate-only"]
    }]
  }'
```

---

## 9. Kubernetes-Specific Patterns

### Init Container for migration

```yaml
spec:
  initContainers:
    - name: migrate
      image: koomi1/retail-app-orders:latest
      command: ["java", "-jar", "app.jar", "--migrate-only"]
      env:
        - name: DB_HOST
          value: "mydb.abc123.us-east-1.rds.amazonaws.com"
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
  containers:
    - name: orders
      image: koomi1/retail-app-orders:latest
      # starts ONLY after initContainer exits 0
```

### Job for one-time migration

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: orders-migrate-v2
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: koomi1/retail-app-orders:latest
          command: ["java", "-jar", "app.jar", "--migrate-only"]
```

### Liveness vs Readiness probe

```yaml
containers:
  - name: orders
    livenessProbe:
      # Is the container alive? Restart if fails.
      httpGet:
        path: /actuator/health/liveness
        port: 8080
      initialDelaySeconds: 60    # wait 60s before first check (JVM startup)
      periodSeconds: 10
      failureThreshold: 3

    readinessProbe:
      # Is the container ready to receive traffic? Remove from LB if fails.
      httpGet:
        path: /actuator/health/readiness
        port: 8080
      initialDelaySeconds: 30    # wait for DB connection to establish
      periodSeconds: 5
      failureThreshold: 3
```

Key difference:
- **Liveness fails** → K8s restarts the container
- **Readiness fails** → K8s removes pod from Service endpoints (no traffic), does NOT restart

This is critical for DB-dependent apps:
- Container starts but DB not connected yet → readiness fails → no traffic sent → no errors to users
- DB connection established → readiness passes → pod added to Service → traffic flows

---

## 10. This Project's DB Strategy

### Current state (in-memory)

All services use in-memory persistence — no external DB needed for local dev or this ECS deployment.

```
catalog  → in-memory product list
cart     → in-memory session map
orders   → in-memory order list
checkout → in-memory checkout state
ui       → no data, pure gateway
```

### Production path (what you'd add)

| Service | In-memory (now) | Production DB | Why |
|---|---|---|---|
| catalog | ✓ | RDS MySQL / PostgreSQL | Product catalog, relational |
| cart | ✓ | DynamoDB | Session data, key-value, fast |
| orders | ✓ | RDS PostgreSQL | Orders, transactions, relational |
| checkout | ✓ | ElastiCache Redis | Temporary checkout state, TTL |
| ui | — | — | No persistence needed |

### How to add RDS for orders (example)

1. **Terraform** — add RDS module:
```hcl
module "rds_orders" {
  source = "../modules/rds"
  identifier        = "${var.env_name}-orders"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "orders"
  username          = "app"
  password          = random_password.orders_db.result
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnet_ids
  tags              = var.tags
}
```

2. **Store password in SSM:**
```hcl
resource "aws_ssm_parameter" "orders_db_password" {
  name  = "/${var.env_name}/orders/db-password"
  type  = "SecureString"
  value = random_password.orders_db.result
}
```

3. **Pass to ECS task:**
```hcl
environment_vars = {
  RETAIL_ORDERS_PERSISTENCE_PROVIDER = "mysql"
  DB_HOST                            = module.rds_orders.endpoint
  DB_PORT                            = "5432"
  DB_NAME                            = "orders"
}
# secrets pulled from SSM at task start
```

4. **Run migration before deploy** (via ECS run-task or init container).

---

## 11. Interview Q&A

---

**Q: Can you run a database in a container in production?**

> Technically yes, but you should not. Containers are ephemeral — if the container restarts or the node it runs on fails, all data inside is lost unless you use persistent volumes. Even with persistent volumes, managing database availability, backups, replication, and failover yourself is complex and error-prone. In production we use managed databases — RDS, DynamoDB, Cloud SQL — and let the cloud provider handle availability and backups. Containers in production are for stateless workloads.

---

**Q: How do containers get database credentials securely?**

> We never hardcode credentials in the container image or Kubernetes YAML. Instead, credentials are stored in a secrets manager — AWS SSM Parameter Store with SecureString (KMS encrypted), AWS Secrets Manager, or HashiCorp Vault. At runtime, the container reads the secret as an environment variable. In ECS, the task definition's `secrets` field pulls from SSM when the task starts. In Kubernetes, we use the External Secrets Operator to sync SSM parameters into K8s Secrets, which are then mounted as env vars. The key point is that the credential never touches the codebase or CI logs.

---

**Q: What is connection pooling and why do you need it with containers?**

> Each app container maintains a pool of open database connections. When you scale to many containers, the total connections can exceed what the database allows — RDS has a `max_connections` limit based on instance size. For example, 100 pods × 10 connections each = 1000 connections, but a db.t3.micro only allows 66. Connection pooling addresses this: a pooler like PgBouncer or AWS RDS Proxy sits between the pods and the database, multiplexing many app connections onto fewer real database connections. Always configure a `max_connections` limit per app instance, and use a pooler for high pod counts.

---

**Q: How do you run database migrations safely in a containerized deployment?**

> The safest pattern is to run migrations as a separate step before deploying the new app version. In Kubernetes, an init container runs the migration and must exit 0 before the app container starts. In ECS, we run a one-off task with an override command before updating the service. The key constraint is that during a rolling deployment, old and new app versions run simultaneously — so migrations must be backwards-compatible. We follow the expand-contract pattern: first add the new column (nullable), then deploy new code that writes to both columns, then drop the old column only after all old pods are gone. Never rename or drop columns in a single deploy.

---

**Q: What is the expand-contract pattern?**

> It's a 3-step migration strategy for zero-downtime schema changes. Step 1 (Expand): add the new column without removing the old one — both columns exist. Step 2 (Transition): deploy app code that reads from the new column but writes to both old and new — old pods still work reading the old column. Step 3 (Contract): once all old pods are gone, drop the old column. This avoids breaking old app versions during the rolling deployment window. The same principle applies to renaming tables or changing column types.

---

**Q: What is the difference between liveness and readiness probes in Kubernetes?**

> Both probes check container health, but they trigger different actions. A liveness probe asks "is this container broken?" — if it fails, Kubernetes restarts the container. A readiness probe asks "is this container ready to serve traffic?" — if it fails, Kubernetes removes the pod from the Service's endpoint list so no traffic is routed to it, but the container is not restarted. For database-connected apps, readiness is critical: the container starts but needs a few seconds to establish the DB connection. During that time, readiness fails → no traffic → no user-facing errors. Once connected, readiness passes → pod added back to the load balancer.

---

**Q: What is a StatefulSet and when do you use it?**

> A StatefulSet is a Kubernetes workload type for stateful applications. Unlike a Deployment, it gives each pod a stable, predictable name (e.g. postgres-0, postgres-1) and a stable DNS entry (postgres-0.postgres.svc.cluster.local). It also creates a dedicated PersistentVolumeClaim per pod, so each replica has its own storage that survives pod restarts. StatefulSets are used for databases, message brokers, and any workload where instance identity matters. For learning or dev environments, running PostgreSQL or Elasticsearch in K8s as a StatefulSet is fine. In production, use managed services.

---

**Q: How does DynamoDB work differently from relational databases in a container context?**

> DynamoDB is an AWS-managed key-value/document store — there's no concept of a connection pool, schema migrations, or running DynamoDB "in" a container. The container just calls the DynamoDB API over HTTPS using the AWS SDK. Authentication is handled by the container's IAM role (via the ECS task role or K8s service account + IRSA), so no username/password is needed. There's no `max_connections` limit — DynamoDB scales automatically. This makes it simpler to use from containers than relational databases.

---

**Q: What happens to a container's data when it restarts?**

> All data written inside the container's filesystem is lost on restart. The container image is immutable — it's recreated fresh from the image each time it starts. To persist data across restarts, you need external storage: RDS/DynamoDB for databases, an S3 bucket for files, ElastiCache for cache state, or a Kubernetes PersistentVolume mounted into the container. For app services (stateless), data loss on restart is fine — the design goal is that any restart should be safe. For databases, always use external managed storage.

---

**Q: How do you handle database connection failures on container startup?**

> Use retry logic with exponential backoff in the app, and configure the readiness probe to fail until the connection is established. The app should not crash on startup if the DB is temporarily unreachable — it should retry. In Spring Boot with Flyway, `spring.flyway.connect-retries=5` retries the DB connection 5 times before failing. In Go, use a retry loop in the DB initialization code. The readiness probe ensures no traffic is sent to the pod until it's actually ready. This is also why `initialDelaySeconds` on probes matters — give the app time to connect before the first probe fires.

---

**Q: What is the difference between AWS SSM Parameter Store and Secrets Manager for container secrets?**

> Both are secure secret stores backed by KMS encryption. Parameter Store SecureString is simpler and cheaper (free for standard tier) — good for individual database passwords and config values. Secrets Manager costs more but adds automatic rotation (it can rotate RDS passwords automatically and push the new value to the app), cross-account access, and a richer API. For containers, both work the same way: the execution role has SSM/Secrets Manager read permission, and the credential is injected as an env var at task start. For production with rotation requirements, use Secrets Manager. For static configs and simple secrets, Parameter Store is sufficient.

---

*Last updated: 2026-04*

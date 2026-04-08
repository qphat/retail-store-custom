# CI/CD for ECS Fargate + Terraform Notes

Learning notes for the retail-store-sample-app CI/CD pipeline.
Covers GitHub Actions, OIDC, ECS deploy patterns, Terraform automation,
drift detection, and security scanning.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [OIDC — Why No Long-Lived Credentials](#2-oidc--why-no-long-lived-credentials)
3. [Terraform CI/CD (terraform.yml)](#3-terraform-cicd-terraformyml)
4. [Application CI/CD (ci.yml)](#4-application-cicd-ciyml)
5. [ECS Deploy Pattern — Task Definition Update](#5-ecs-deploy-pattern--task-definition-update)
6. [Security Scanning — tfsec + checkov](#6-security-scanning--tfsec--checkov)
7. [Health Checks — Per-Service vs Smoke Test](#7-health-checks--per-service-vs-smoke-test)
8. [Drift Detection (terraform-drift.yml)](#8-drift-detection-terraform-driftyml)
9. [Concurrency — Race Condition Prevention](#9-concurrency--race-condition-prevention)
10. [How to Implement — Step by Step](#10-how-to-implement--step-by-step)
11. [GitHub Actions Concepts](#11-github-actions-concepts)
12. [Common Issues & Fixes](#12-common-issues--fixes)
13. [Interview Q&A](#13-interview-qa)

---

## 1. Architecture Overview

### Full pipeline flow

```
Developer pushes code
        │
        ├─── touches src/**  ──────────────────────────────────────────────┐
        │                                                                   ▼
        │                                                            ci.yml triggers
        │                                                                   │
        │                                              detect-changes (dorny/paths-filter)
        │                                                ["catalog", "ui"]
        │                                                                   │
        │                                              build matrix (per changed service)
        │                                                ├─ setup runtime (Go/Java/Node)
        │                                                ├─ docker build + load
        │                                                ├─ trivy scan (block CRITICAL CVEs)
        │                                                └─ docker push :{sha} + :latest
        │                                                                   │
        │                                              deploy matrix (per changed service)
        │                                                ├─ OIDC → AWS credentials
        │                                                ├─ describe current task def
        │                                                ├─ render new task def (:{sha} image)
        │                                                ├─ tag task def (GitSHA, RunID)
        │                                                ├─ register new task def revision
        │                                                ├─ update ECS service
        │                                                ├─ wait services-stable
        │                                                └─ HTTP health check via ALB
        │                                                                   │
        │                                              smoke-test (all services together)
        │                                                └─ curl all 6 endpoints via ALB
        │
        └─── touches terraform/**  ────────────────────────────────────────┐
                                                                           ▼
                                                                  terraform.yml triggers
                                                                           │
                                    On PR:                    On push to main:
                                    ├─ detect changed envs    └─ apply-dev (auto)
                                    ├─ lint (fmt + validate)
                                    ├─ security-scan          On workflow_dispatch:
                                    │  (tfsec + checkov)      └─ apply-manual
                                    └─ plan per env               (staging/prod)
                                       └─ PR comment               (approval gate)

Every weekday 13:00 VN time:
  terraform-drift.yml
    ├─ plan -detailed-exitcode -lock=false (dev, staging, prod)
    ├─ drift found → open/update GitHub Issue
    └─ no drift → job passes silently
```

### Three workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | push/PR on `src/**` | Build → scan → push → ECS deploy → smoke test |
| `terraform.yml` | push/PR on `terraform/**` | Lint → security scan → plan → apply |
| `terraform-drift.yml` | cron (weekdays) | Detect manual AWS console changes |

---

## 2. OIDC — Why No Long-Lived Credentials

### The old way (bad)

```yaml
# Stored as GitHub secrets — live forever, must be rotated manually
AWS_ACCESS_KEY_ID:     AKIA...
AWS_SECRET_ACCESS_KEY: abc123...
```

Problems:
- Credentials valid until manually rotated or revoked
- If GitHub is compromised, attacker gets permanent AWS access
- Easy to accidentally expose in logs, artifacts, or forks
- No audit trail (all API calls look the same)

### OIDC (OpenID Connect) — the right way

```
GitHub Actions job starts
        │
        │  requests a signed JWT from GitHub's OIDC endpoint
        │  JWT contains: repo, branch, workflow, actor, sha
        ▼
GitHub OIDC Endpoint (token.actions.githubusercontent.com)
        │
        │  returns JWT (valid ~1 hour, scoped to this job)
        ▼
AWS STS AssumeRoleWithWebIdentity
        │  verifies JWT signature against OIDC provider thumbprint
        │  checks Condition: repo == "qphat/retail-store-custom"
        ▼
Temporary credentials (valid 1 hour, expire when job ends)
        │
        ▼
GitHub Actions uses these for AWS API calls
```

### OIDC trust policy (who can assume the role)

```hcl
Condition = {
  StringLike = {
    # Only this specific repo — not any GitHub repo
    "token.actions.githubusercontent.com:sub" = "repo:qphat/retail-store-custom:*"
  }
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
  }
}
```

The `sub` claim contains: `repo:{owner}/{repo}:{ref}`. The `*` wildcard allows any branch/tag.
To restrict to main branch only: `"repo:qphat/retail-store-custom:ref:refs/heads/main"`.

### GitHub Actions config

```yaml
permissions:
  id-token: write   # required — allows the job to request an OIDC token

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ vars.AWS_ROLE_ARN }}   # not a secret — role ARNs are not sensitive
      aws-region: us-east-1
```

`vars.AWS_ROLE_ARN` is a GitHub **variable** (not secret) because role ARNs are not sensitive — they're just identifiers, not credentials.

### Setup (one-time)

```bash
# 1. Create the OIDC provider + IAM role via Terraform
cd terraform/global
terraform init && terraform apply

# 2. Get the role ARN from output
terraform output github_actions_role_arn
# arn:aws:iam::123456789012:role/github-actions-retail-store

# 3. Set as GitHub variable (not secret):
# Repo → Settings → Variables → Actions → New variable
# Name: AWS_ROLE_ARN
# Value: arn:aws:iam::123456789012:role/github-actions-retail-store
```

---

## 3. Terraform CI/CD (terraform.yml)

### Job flow on a PR

```
PR opened touching terraform/modules/ecs-service/main.tf
        │
        ├─ detect-env: paths-filter detects dev + staging changed (modules affect both)
        │
        ├─ lint (parallel with detect-env):
        │   terraform fmt -check -recursive terraform/
        │   terraform init -backend=false && terraform validate (for each env)
        │
        ├─ security-scan (parallel):
        │   tfsec terraform/ → SARIF to Security tab
        │   checkov terraform/ → SARIF to Security tab
        │
        └─ plan (matrix: dev, staging):
            terraform init -lock-timeout=5m
            terraform plan -no-color -lock-timeout=5m -out=tfplan
            → uploads tfplan artifact
            → posts collapsible PR comment with plan output
```

### PR comment format

```markdown
## Terraform Plan — `dev`

<details>
<summary>Show plan</summary>

```hcl
  # aws_ecs_task_definition.this will be updated in-place
  ~ resource "aws_ecs_task_definition" "this" {
      ~ cpu    = "256" -> "512"
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

</details>

Commit: `abc1234`
Run: https://github.com/...
```

### Why `-backend=false` for validate

`terraform validate` only checks syntax and references — it doesn't need state.
`-backend=false` skips state backend initialization (no S3 connection), making it faster
and usable without AWS credentials.

### Why `-lock-timeout=5m`

If another `terraform apply` is running and holds the DynamoDB state lock, the plan waits
up to 5 minutes instead of failing immediately. This handles:
- Developer running `terraform apply` locally at the same time
- Previous CI run that died mid-apply and didn't release the lock (auto-releases after 1h)

### Apply: dev auto, staging/prod manual

```yaml
# Dev: runs automatically on every merge to main
apply-dev:
  if: github.event_name == 'push'
  environment: dev   # GitHub Environment with no protection rules

# Staging/Prod: triggered manually, requires approval
apply-manual:
  if: github.event_name == 'workflow_dispatch'
  environment: ${{ github.event.inputs.environment }}
  # GitHub Environment has required reviewers configured
  # Job pauses here until reviewer approves in GitHub UI
```

**Why not auto-apply staging/prod?**
- Infrastructure changes to prod must be human-reviewed
- `terraform plan` on PR shows what changes, but the plan runs against the code at that moment
- Between PR merge and auto-apply, another change could merge — reviewer sees the real apply
- GitHub Environments provide an audit trail: who approved, when, what SHA

### Concurrency guard

```yaml
concurrency:
  group: terraform-${{ github.event.inputs.environment || 'dev' }}
  cancel-in-progress: false
```

`cancel-in-progress: false` is critical for terraform. If two PRs merge quickly:
- Two `apply` jobs both start
- First job acquires DynamoDB lock, starts apply
- If second job cancelled the first mid-apply → partial state, infrastructure mismatch
- Instead: second job waits in the queue, runs after first completes cleanly

---

## 4. Application CI/CD (ci.yml)

### Four jobs, linear dependency

```
detect-changes
      │
      ▼
build (matrix: per changed service) — parallel
      │ only on push to main
      ▼
deploy (matrix: per changed service) — parallel
      │ all deploys must complete
      ▼
smoke-test (single job, all services)
```

### detect-changes: why paths-filter

Without paths-filter, every push rebuilds all 5 services (~15 min).
With paths-filter, only changed services rebuild:

```yaml
filters: |
  catalog:
    - 'src/catalog/**'
    - 'nx.json'           # root config affects all
    - 'yarn.lock'         # dependency change affects all
```

Output: `["catalog"]` or `["catalog","ui"]` — JSON array used as build matrix.

### Build: one image per service

Each service has its own Dockerfile in `src/<service>/`.
The matrix runs them in parallel:

```
catalog (Go)     → 2 min
cart (Java)      → 4 min    ← all run simultaneously
orders (Java)    → 4 min
checkout (Node)  → 3 min
ui (Java)        → 4 min
```

Without `fail-fast: false`, one failing service would cancel all others.
With `fail-fast: false`, each service's result is independent.

### Image tags: two tags per push

```
koomi1/retail-app-catalog:abc1234def   ← SHA tag (immutable, pinned)
koomi1/retail-app-catalog:latest       ← moving tag (convenience for local use)
```

**SHA tag in ECS task definition** — each task def revision is pinned to an exact image.
**`:latest` in Docker Hub** — so `docker pull koomi1/retail-app-catalog` works without specifying a SHA.

Never use `:latest` in production deployments — it's mutable and unpredictable.

---

## 5. ECS Deploy Pattern — Task Definition Update

### Why update the task definition (not `--force-new-deployment`)

**`--force-new-deployment` + `:latest` approach (wrong):**
```
Push image :latest to Docker Hub
aws ecs update-service --force-new-deployment
  → ECS stops old tasks, starts new tasks
  → New tasks pull :latest from Docker Hub
```

Problem: if two pushes happen close together, the second `:latest` might be pulled
for the first deploy. The running image doesn't match the git commit that triggered deploy.
No audit trail, no rollback path.

**Task definition update approach (correct):**
```
Push image :{sha} to Docker Hub
Download current task definition JSON
Update container image: catalog → koomi1/retail-app-catalog:{sha}
Register new task definition revision → dev-catalog:5
aws ecs update-service --task-definition dev-catalog:5
  → ECS starts new tasks using exactly revision 5
  → New tasks pull :{sha} — immutable, matches this git commit
```

Benefits:
- **Audit trail**: ECS console shows revision history → sha → git commit
- **Rollback**: `aws ecs update-service --task-definition dev-catalog:4`
- **Pinned image**: deployed image never changes unexpectedly

### Step-by-step deploy

```yaml
# Step 1: Get current task definition
- run: |
    aws ecs describe-task-definition \
      --task-definition dev-catalog \
      --query taskDefinition \
      > task-def.json

# Step 2: Tag with deploy metadata
- run: |
    jq '.tags += [
      {"key": "GitSHA",     "value": "abc1234"},
      {"key": "RunID",      "value": "12345678"},
      {"key": "DeployedBy", "value": "github-actions"}
    ]' task-def.json > task-def-tagged.json

# Step 3: Render new image into task def
- uses: aws-actions/amazon-ecs-render-task-definition@v1
  with:
    task-definition: task-def-tagged.json
    container-name: catalog
    image: koomi1/retail-app-catalog:abc1234

# Step 4: Register + update (with 3x retry)
- run: |
    TASK_DEF_ARN=$(aws ecs register-task-definition \
      --cli-input-json file://task-def-rendered.json \
      --query 'taskDefinition.taskDefinitionArn' \
      --output text)
    # → arn:aws:ecs:us-east-1:123:task-definition/dev-catalog:5

    aws ecs update-service \
      --cluster dev-retail-store \
      --service dev-catalog \
      --task-definition "$TASK_DEF_ARN"

    aws ecs wait services-stable \
      --cluster dev-retail-store \
      --services dev-catalog
    # polls every 15s for up to 40 attempts (10 min)
```

### ECS rolling deploy internals

When you call `update-service`:
1. ECS starts new tasks with the new task definition (up to `maximum_percent = 200`)
2. New tasks register with the ALB target group
3. ALB health checks the new tasks
4. Once new tasks pass health checks, ALB routes traffic to them
5. ECS drains old tasks from ALB (connections finish, no new connections)
6. Old tasks stop
7. `services-stable` = `running_count == desired_count` and all tasks are healthy

```
Before: [old-task-1] [old-task-2]
During: [old-task-1] [old-task-2] [new-task-1] [new-task-2]  ← max 200%
After:                             [new-task-1] [new-task-2]
```

No downtime — ALB always has healthy targets.

### Rollback

```bash
# List task definition revisions
aws ecs list-task-definitions --family-prefix dev-catalog

# Rollback to previous revision
aws ecs update-service \
  --cluster dev-retail-store \
  --service dev-catalog \
  --task-definition dev-catalog:4   # previous good revision
```

Or automate via a workflow_dispatch job with `revision` input.

---

## 6. Security Scanning — tfsec + checkov

### Why two tools

No single tool catches everything. They have overlapping but distinct rule sets:

| Aspect | tfsec | checkov |
|---|---|---|
| Focus | Terraform-native, AWS-deep | Multi-framework (TF, CF, Docker, K8s) |
| Speed | Fast (Go binary) | Slower (Python) |
| Output | Inline code annotations | SARIF, JSON, CLI table |
| AWS rules | Excellent | Good |
| Custom policies | Limited | Yes (Python or YAML) |

Running both = better coverage.

### What they catch in this project

**tfsec findings:**

```
MEDIUM: aws-ec2-no-public-ingress-sgr
  modules/alb/main.tf:22
  Security group allows ingress from 0.0.0.0/0 on port 80
  → Expected for the ALB (public-facing by design)
  → Suppress with: #tfsec:ignore:aws-ec2-no-public-ingress-sgr

HIGH: aws-cloudwatch-log-group-retention-period
  modules/ecs-cluster/main.tf:15
  Log group has no retention period set
  → Fix: add retention_in_days = 7

CRITICAL: aws-iam-no-policy-wildcards
  terraform/global/main.tf:50
  IAM policy uses "*" for Resource
  → Acceptable for Terraform apply role (needs broad access)
  → Suppress or scope down per resource type
```

**checkov findings:**

```
FAILED: CKV_AWS_97 "Ensure AWS ECS task definition has memory defined"
  → Already handled — memory is required in our task definition

FAILED: CKV_AWS_336 "Ensure ECS task definition has read-only root filesystem"
  modules/ecs-service/main.tf
  → Add: readonlyRootFilesystem = true in container definition
  → (may require app changes if app writes to disk)

FAILED: CKV2_AWS_5 "Ensure S3 bucket has access logging enabled"
  modules/alb/main.tf
  → For learning: suppress; for prod: add access_logs block to ALB
```

### Inline suppressions

```hcl
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
resource "aws_security_group" "alb" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]  # public ALB — intentional
    ...
  }
}
```

```hcl
# checkov:skip=CKV2_AWS_5:ALB access logs not required for dev
resource "aws_lb" "main" { ... }
```

### SARIF output → GitHub Security tab

Both tools output SARIF (Static Analysis Results Interchange Format). GitHub reads SARIF files and:
- Shows findings in the repo's **Security → Code scanning alerts** tab
- Annotates the PR diff with inline comments at the specific line
- Tracks which alerts are fixed vs still open

```yaml
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: checkov-results.sarif
# → Appears in: repo → Security → Code scanning → checkov alerts
```

---

## 7. Health Checks — Per-Service vs Smoke Test

### Two layers of verification

```
deploy job (per service):
  ECS wait services-stable     ← ECS/ALB agrees the task is healthy
  HTTP health check via ALB    ← YOU verify the endpoint actually responds

smoke-test job (all services):
  curl all 6 endpoints         ← verify everything works TOGETHER
```

### Per-service health check

```bash
URL="http://${ALB}${HEALTH_PATH}"   # e.g. http://alb.dns/health

for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL")
  if [ "$STATUS" = "200" ]; then exit 0; fi
  sleep 15
done
exit 1   # fail deploy if health check doesn't pass in 2.5 min
```

Why this check exists even after `aws ecs wait services-stable`:
- ECS "stable" = tasks are running and ALB considers them healthy
- But ALB health check path might be `/health` returning 200 while the app is broken elsewhere
- The per-service check verifies the SAME path that smoke test will check

### Smoke test — all services

```bash
check "ui"       "$BASE/"                    "200"
check "catalog"  "$BASE/catalogue"           "200"
check "cart"     "$BASE/api/cart/health"     "200"
check "orders"   "$BASE/api/orders/health"   "200"
check "checkout" "$BASE/api/checkout/health" "200"
check "kibana"   "$BASE/kibana/api/status"   "200"
```

**Why smoke test catches things per-service check misses:**

| Issue | Per-service check | Smoke test |
|---|---|---|
| Service A's task is unhealthy | ✓ catches | ✓ catches |
| Service B's health path broken | ✗ doesn't check B | ✓ catches |
| ALB rule conflict (A's rule blocks B) | ✗ checks via A's path | ✓ catches B's path |
| ui can't reach catalog (env var wrong) | ✗ ui's /actuator/health still 200 | ✓ catches when /catalogue fails |
| Cloud Map DNS resolution broken | ✗ | ✓ catches on service-to-service calls |

### Health paths per service

| Service | Runtime | Health path | Reason |
|---|---|---|---|
| ui | Spring Boot | `/actuator/health` | Spring Boot Actuator auto-exposes this |
| catalog | Go/Gin | `/health` | Custom handler in the Go service |
| cart | Spring Boot | `/actuator/health` | Spring Boot Actuator |
| orders | Spring Boot | `/actuator/health` | Spring Boot Actuator |
| checkout | NestJS | `/health` | NestJS health module |

---

## 8. Drift Detection (terraform-drift.yml)

### What is drift?

Drift = real AWS infrastructure differs from what Terraform state says it should be.

Causes:
- Someone clicked in the AWS console to "fix" something quickly
- Manual `aws` CLI command to change a security group rule
- AWS automatically modified a resource (e.g. updated a managed policy)
- A previous `terraform apply` partially failed and left inconsistent state

### How `terraform plan -detailed-exitcode` works

```bash
terraform plan -detailed-exitcode -lock=false -refresh=true

# Exit codes:
# 0 = no changes (no drift)
# 1 = error (plan failed)
# 2 = changes detected (drift exists!)
```

`-refresh=true`: Terraform calls AWS APIs to check the real state of every resource.
Compares real state to what's in `.tfstate`. Any difference → exit code 2.

`-lock=false`: Drift check is read-only. It refreshes state but doesn't write anything.
No DynamoDB lock needed. Avoids blocking real applies running at the same time.

### Drift issue lifecycle

```
Monday 13:00 — drift workflow runs
  dev: exit code 0 (no drift) ✓
  staging: exit code 2 (drift!) → creates GitHub Issue #42
    Title: "[Drift] Terraform drift in staging"
    Labels: terraform-drift, staging
    Body: plan output showing changed resources

Tuesday 13:00 — drift workflow runs again
  staging: still exit code 2 → adds comment to Issue #42
    "Drift still present — 2026-04-09T06:00:00Z"

Tuesday afternoon — engineer runs terraform apply for staging
  drift fixed, staging now matches Terraform state

Wednesday 13:00 — drift workflow runs
  staging: exit code 0 (no drift) ✓
  Engineer closes Issue #42 manually
```

### What drift looks like in plan output

```hcl
# AWS console changed the security group rule manually:
  ~ resource "aws_security_group" "service" {
      ~ ingress {
          ~ cidr_blocks = ["10.0.0.0/16"] -> ["0.0.0.0/0"]   # someone opened it to internet!
        }
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

The plan shows what Terraform will DO to restore the desired state (re-restrict to VPC CIDR).

### GitHub Issue deduplication

```javascript
// Check for existing open drift issue for this env
const existing = await github.rest.issues.listForRepo({
  state: 'open',
  labels: `terraform-drift,${env}`,
});

if (existing.length === 0) {
  // Create new issue
  await github.rest.issues.create({ ... });
} else {
  // Add comment to existing issue — no duplicate issues
  await github.rest.issues.createComment({ issue_number: existing[0].number, ... });
}
```

Without deduplication: 5 weekdays = 5 separate issues for the same drift. Noise.
With deduplication: one issue per environment, updated with new timestamps.

---

## 9. Concurrency — Race Condition Prevention

### The race condition problem

Two developers merge PRs at the same time:
```
11:00:01 — PR #10 merges (touches catalog)
11:00:05 — PR #11 merges (also touches catalog)

11:00:10 — deploy job for PR #10 starts
11:00:12 — deploy job for PR #11 starts

11:00:15 — PR #10's job: register task def dev-catalog:5 (image: sha-PR10)
11:00:16 — PR #11's job: register task def dev-catalog:6 (image: sha-PR11)
11:00:17 — PR #10's job: update-service --task-definition dev-catalog:5 ← OVERWRITTEN immediately
11:00:18 — PR #11's job: update-service --task-definition dev-catalog:6
11:00:20 — PR #10's job: wait services-stable → stable on :6 (PR#11's image!)
11:00:20 — PR #10's job: health check → passes (but running PR#11's code, not PR#10's)

Result: PR #10's deploy "succeeded" but ECS is running PR#11's code. Audit trail broken.
```

### GitHub Actions concurrency fix

```yaml
deploy:
  concurrency:
    group: ecs-deploy-${{ matrix.service }}  # one group per service
    cancel-in-progress: false                 # queue, don't cancel
```

With this:
```
11:00:10 — deploy job for PR #10 starts, acquires lock for "ecs-deploy-catalog"
11:00:12 — deploy job for PR #11 tries to start, QUEUED (waiting for PR #10)

11:02:30 — PR #10's deploy completes (ECS stable, health check passes)
11:02:31 — PR #11's deploy starts, runs with full context
```

**Why `cancel-in-progress: false`?**
If `cancel-in-progress: true`, PR #11's start would cancel PR #10's job mid-deploy —
potentially leaving ECS with a partial new task definition, or a mix of old and new tasks.
`false` = safe queue, always complete the in-progress deploy before starting the next.

### Terraform concurrency

Same principle for Terraform:

```yaml
terraform.yml:
  concurrency:
    group: terraform-${{ github.event.inputs.environment || 'dev' }}
    cancel-in-progress: false
```

Prevents two `terraform apply` jobs from running simultaneously on the same environment —
which would cause state file corruption or conflicting resource creation.

---

## 10. How to Implement — Step by Step

### Prerequisites

```bash
# 1. AWS CLI configured with admin credentials
aws sts get-caller-identity

# 2. Terraform installed (via mise)
terraform version   # should be >= 1.5

# 3. GitHub repo with secrets/vars:
#    Secrets: DOCKER_USERNAME, DOCKER_PASSWORD
#    Variables: DOCKER_REGISTRY, IMAGE_PREFIX
```

### Step 1: Create state backend (one-time)

```bash
cd terraform
./scripts/setup-backend.sh
# Creates: S3 bucket retail-store-tf-state-{account_id}
# Creates: DynamoDB table retail-store-tf-lock
# Patches: all backend.tf files with correct bucket name
```

### Step 2: Create OIDC role (one-time)

```bash
cd terraform/global
terraform init
terraform plan    # review what will be created
terraform apply

# Copy the output:
terraform output github_actions_role_arn
# arn:aws:iam::123456789012:role/github-actions-retail-store
```

### Step 3: Configure GitHub

```
Repo → Settings → Variables → Actions → New repository variable:
  AWS_ROLE_ARN  = arn:aws:iam::123456789012:role/github-actions-retail-store
  AWS_REGION    = us-east-1

Repo → Settings → Environments → New environment:
  Name: staging
  → Add required reviewers: [your username]

  Name: prod
  → Add required reviewers: [your username]
  → Wait timer: 5 minutes

Repo → Settings → Environments → dev:
  → No protection rules (auto-deploy)
```

### Step 4: Deploy infrastructure

```bash
cd terraform/environments/dev
terraform init
terraform plan    # review all resources
terraform apply   # creates VPC, ECS cluster, ALB, logging stack, services
```

Verify:
```bash
terraform output alb_dns_name
curl http://{alb_dns}/health
```

### Step 5: Test CI/CD

```bash
# Test app CI/CD:
# 1. Make a small change to src/catalog/
git add . && git commit -m "test: trigger catalog deploy"
git push origin main

# Watch in GitHub Actions:
# detect-changes → ["catalog"]
# build (catalog) → scan → push :{sha}
# deploy (catalog) → task def update → health check
# smoke-test → all services

# Test terraform CI/CD:
# 1. Open a PR changing terraform/modules/alb/main.tf
# → Check PR for plan comment
# 2. Merge PR
# → Check Actions for apply-dev job
```

### Step 6: Test drift detection

```bash
# Manually trigger drift check:
# GitHub → Actions → Terraform Drift Detection → Run workflow

# Or simulate drift:
# Change something in AWS console (e.g. add a tag to the VPC)
# Then run drift workflow → should open a GitHub Issue
```

### Step 7: Configure label for drift issues

```bash
# Create labels in GitHub:
# Repo → Issues → Labels → New label
gh label create "terraform-drift" --color "D93F0B" --description "Terraform infrastructure drift"
gh label create "dev" --color "0075ca"
gh label create "staging" --color "e4e669"
gh label create "prod" --color "d73a4a"
```

---

## 11. GitHub Actions Concepts

### Workflow triggers

```yaml
on:
  push:
    branches: [main]          # runs when code merges to main
    paths: ['terraform/**']   # only if these paths changed

  pull_request:
    branches: [main]          # runs on PRs targeting main

  schedule:
    - cron: '0 6 * * 1-5'   # runs at 06:00 UTC Mon-Fri

  workflow_dispatch:          # manually triggered via GitHub UI or API
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]
```

### Permissions

```yaml
permissions:
  contents: read        # checkout repo
  id-token: write       # request OIDC token (required for OIDC)
  pull-requests: write  # post PR comments
  issues: write         # create/comment on issues
  security-events: write # upload SARIF to Security tab
```

Least-privilege: only grant what each workflow needs.

### Jobs, needs, and if conditions

```yaml
jobs:
  detect-changes:
    ...

  build:
    needs: detect-changes     # waits for detect-changes to finish
    if: needs.detect-changes.outputs.services != '[]'   # skip if nothing changed

  deploy:
    needs: build              # waits for build to finish
    if: github.event_name == 'push'   # only on push (not PRs)

  smoke-test:
    needs: deploy             # waits for ALL deploy matrix jobs
    if: github.event_name == 'push'
```

### Matrix strategy

```yaml
strategy:
  fail-fast: false      # don't cancel other matrix jobs if one fails
  matrix:
    service: ["catalog", "ui"]
    include:
      - service: catalog
        health-path: /health   # attach extra metadata to each matrix entry
      - service: ui
        health-path: /actuator/health
```

`matrix.service` is iterated — one job per entry. `include` adds extra keys to each entry.
`fromJson()` converts a JSON string to an array: `fromJson('["catalog","ui"]')`.

### Outputs between jobs

```yaml
jobs:
  detect-changes:
    outputs:
      services: ${{ steps.filter.outputs.changes }}   # declare output
    steps:
      - id: filter
        run: echo "changes=[\"catalog\"]" >> $GITHUB_OUTPUT   # set output

  build:
    needs: detect-changes
    matrix:
      service: ${{ fromJson(needs.detect-changes.outputs.services) }}   # consume output
```

### Environment protection rules

```yaml
jobs:
  apply-prod:
    environment: prod   # references a GitHub Environment

# GitHub Environment "prod" configured with:
# - Required reviewers: [koomi]
# - Wait timer: 5 minutes
#
# When this job runs:
# 1. GitHub pauses the job
# 2. Sends notification to required reviewers
# 3. Job resumes only after approval
# 4. Timer counts down (even after approval, job waits 5 min)
# 5. Apply runs
```

### Cache action

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.terraform.d/plugin-cache     # what to cache
    key: terraform-${{ runner.os }}-${{ hashFiles('**/.terraform.lock.hcl') }}
    # key changes if .terraform.lock.hcl changes (new provider versions)
    restore-keys: terraform-${{ runner.os }}-
    # fallback key if exact key not found — uses the most recent matching cache
```

First run: cache miss → downloads providers (~200MB), saves to cache.
Subsequent runs: cache hit → skips download. Saves 1-2 min per job.

### GITHUB_OUTPUT vs echo

```bash
# Old way (deprecated):
echo "::set-output name=my_var::value"

# New way (required):
echo "my_var=value" >> $GITHUB_OUTPUT

# Multi-line value:
{
  echo "plan_output<<EOF"
  cat plan.txt
  echo "EOF"
} >> $GITHUB_OUTPUT
```

---

## 12. Common Issues & Fixes

### `Error: No OIDC token received`

**Cause:** `permissions.id-token: write` missing from workflow.
**Fix:** Add to the workflow-level permissions block.

---

### `Error: Could not assume role` (403)

**Cause 1:** IAM role's trust policy `sub` condition doesn't match the repo/branch.
**Fix:** Check the exact value: `token.actions.githubusercontent.com:sub` = `repo:owner/repo:ref:refs/heads/main`. Use `StringLike` with `*` for flexibility.

**Cause 2:** OIDC provider thumbprint is wrong.
**Fix:** Thumbprint for `token.actions.githubusercontent.com` is `6938fd4d98bab03faadb97b34396831e3780aea1`. Verify at: `openssl s_client -connect token.actions.githubusercontent.com:443 | openssl x509 -fingerprint -noout -sha1`.

---

### `Error acquiring the state lock`

**Cause:** A previous `terraform apply` died mid-run and didn't release the DynamoDB lock.
**Fix:**
```bash
terraform force-unlock <LOCK_ID>
# Lock ID is shown in the error message
```

Or wait — locks auto-expire after 1 hour.

---

### `aws ecs wait services-stable` times out (10 min)

**Cause 1:** New task fails health checks — container crash loop, wrong health path.
**Fix:** Check ECS console → service → events, and CloudWatch logs for the service.

**Cause 2:** Java service takes >10 min to start (OOM, insufficient memory).
**Fix:** Increase task memory in tfvars, or increase `health_check_start_period`.

**Cause 3:** Task can't pull image from Docker Hub (rate limit or wrong credentials).
**Fix:** Check ECS task stopped reason in the console.

---

### `terraform fmt -check` fails

**Cause:** Someone edited `.tf` files without running `terraform fmt`.
**Fix:**
```bash
terraform fmt -recursive terraform/
git add -u && git commit -m "style: terraform fmt"
```

Set up a pre-commit hook to auto-format:
```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.77.0
    hooks:
      - id: terraform_fmt
```

---

### Smoke test fails for one service after deploy

**Likely cause:** The service that wasn't redeployed has a startup issue, or inter-service communication broken.
**Debug:**
```bash
# Check ECS service events
aws ecs describe-services \
  --cluster dev-retail-store \
  --services dev-catalog \
  --query 'services[0].events[:5]'

# Check container logs
aws logs get-log-events \
  --log-group-name /ecs/dev/catalog \
  --log-stream-name "ecs/catalog/$(aws ecs list-tasks --cluster dev-retail-store --service-name dev-catalog --query 'taskArns[0]' --output text | cut -d/ -f3)"
```

---

### Drift detection opens issue every day even after fix

**Cause:** `.tfstate` not updated — `terraform apply` wasn't run after the manual change.
**Fix:** Run `terraform apply` for the affected environment. It will restore the desired state AND update `.tfstate` to match.

---

### Real AWS deployment: services show `0/1 Tasks running` but containers are RUNNING

**What happened:** ECS task containers both show `RUNNING` but the service still shows `0/1`.

**Why:** ECS counts a task as "running" at the *service* level only after the ALB target group
marks it healthy. The task is up, but if the ALB health check fails the service count stays 0.

**Debug:**
```bash
# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn <ARN> \
  --query 'TargetHealthDescriptions[*].{State:TargetHealth.State,Reason:TargetHealth.Reason}'
# initial = warming up (wait)
# unhealthy = endpoint not responding (check health path, port, security group)
```

---

### Real AWS deployment: UI returns 500 — backend services unreachable

**Root cause:** Two bugs together:
1. App services were never registered with Cloud Map → DNS `catalog.dev.local` didn't exist
2. Service URLs missing `:8080` → `http://catalog.dev.local` defaults to port 80

**Fix applied:**
- Added `aws_service_discovery_service` + `service_registries` to `ecs-service` module
- Added VPC CIDR ingress rule (inter-service traffic doesn't go through ALB)
- Added `:8080` to all `RETAIL_UI_ENDPOINTS_*` and `RETAIL_CHECKOUT_ENDPOINTS_ORDERS` vars

**Key insight:** Cloud Map A records = IP only. SRV records include port but Spring Boot's
`RestTemplate` doesn't do SRV lookup by default. Always put the port explicitly in the URL.

---

## 13. Interview Q&A

### OIDC & Credentials

**Q: Why use OIDC instead of access key/secret in GitHub Actions?**

Long-lived access keys are a security liability — if leaked (in logs, artifacts, a compromised runner), the attacker has permanent AWS access until someone manually rotates the key. OIDC credentials are short-lived (1 hour) and scoped to the specific GitHub job. They're automatically generated and expired — no rotation needed, no secret to leak. Additionally, the IAM role's trust policy restricts which repo/branch can assume it, so even if the token were stolen, it's only valid for that specific job's duration.

---

**Q: What is a thumbprint in OIDC configuration and why is it needed?**

The thumbprint is the SHA1 fingerprint of the root CA certificate for GitHub's OIDC TLS endpoint. AWS uses it to verify that JWT tokens it receives actually come from GitHub's OIDC endpoint and haven't been tampered with. Without this, any server could claim to be GitHub's OIDC provider. The thumbprint `6938fd4d98bab03faadb97b34396831e3780aea1` is stable and rarely changes — it only needs updating if GitHub rotates their root CA.

---

**Q: What's the difference between a GitHub secret and a GitHub variable?**

Secrets are encrypted and masked in logs — used for sensitive values like passwords, tokens, API keys. Once set, you can't read them back. Variables are plaintext configuration values visible in logs — used for non-sensitive config like region names, cluster names, role ARNs. The IAM role ARN goes in a variable (not secret) because it's an identifier, not a credential — knowing the ARN doesn't give you any access.

---

### CI/CD Patterns

**Q: Why update the ECS task definition instead of using `--force-new-deployment`?**

`--force-new-deployment` with `:latest` is non-deterministic. If two pushes happen quickly, ECS might pull a newer `:latest` than the one that triggered the deploy. There's no audit trail and rollback means guessing which image was running. Task definition updates create a numbered revision (e.g. `dev-catalog:5`) pinned to an exact SHA image (`:{git_sha}`). Every deploy maps git commit → Docker image → task definition revision. Rollback is `aws ecs update-service --task-definition dev-catalog:4` — precise and auditable.

---

**Q: What does `cancel-in-progress: false` mean in a concurrency group and why use it for deployments?**

By default with `cancel-in-progress: true`, when a new run starts in the same concurrency group, it cancels any in-progress run. For deployments this is dangerous — cancelling a deployment mid-flight can leave ECS in a mixed state with some old and some new tasks, or with a partial task definition registration. `cancel-in-progress: false` queues the second run — it waits for the first to complete cleanly before starting. The slight delay is worth the safety guarantee.

---

**Q: Why run a smoke test after individual service health checks?**

Individual health checks verify that each service's own health endpoint returns 200. But they don't verify inter-service communication. For example: the `ui` service's `/actuator/health` returns 200 even if the `RETAIL_UI_ENDPOINTS_CATALOG` environment variable points to the wrong URL. The smoke test hits `$ALB/catalogue` — which goes through ui → catalog → response. If catalog is broken or unreachable from ui, the smoke test catches it. It also catches ALB listener rule conflicts where one service's rule shadows another.

---

### Terraform CI/CD

**Q: Why run `terraform plan` on PRs but not `terraform apply`?**

Plan shows reviewers exactly what will change before it changes. Apply is irreversible for many resources — deleting a database or security group in staging could affect running services. PRs are also speculative — the branch might not merge. Running apply on every PR would apply changes that get reverted when the PR is closed. The correct flow: plan shows intent on PR, apply executes on merge (for dev) or on explicit approval (for staging/prod).

---

**Q: What does `-lock=false` do in the drift detection plan and when is it safe?**

The `-lock=false` flag skips acquiring the DynamoDB state lock before running. Normally, `terraform plan` and `terraform apply` both acquire a lock to prevent concurrent modifications. Drift detection is read-only — it runs `terraform refresh` to compare real AWS state to `.tfstate`, but it never modifies the state file. Since no writes happen, locking is unnecessary. Using `-lock=false` means drift detection doesn't block real applies that happen to run at the same time.

---

**Q: How does `terraform plan -detailed-exitcode` enable drift detection?**

Normally `terraform plan` exits 0 on success (with or without changes) and 1 on error. With `-detailed-exitcode`, the exit codes are: 0 = success, no changes; 1 = error; 2 = success, changes present. Exit code 2 means Terraform found differences between real AWS state and desired state — drift. This allows a shell script to distinguish "no changes" from "changes detected" without parsing the plan text output.

---

**Q: Why does staging/prod Terraform apply require manual approval while dev is automatic?**

Dev is where you discover problems — auto-deploy there gets fast feedback. Staging and prod affect shared or customer-facing resources. An automated apply of a PR that accidentally deletes a security group in prod would be catastrophic. GitHub Environments provide a pause with required reviewers — the plan was already shown on the PR, so the reviewer knows what they're approving. The 5-minute wait timer on prod adds an extra window to abort if someone spots an issue after approval.

---

**Q: What is tfsec vs checkov and why run both?**

tfsec is a fast, Terraform-native scanner written in Go. It has excellent AWS-specific rules and supports inline suppressions with comments. checkov is a broader policy engine (Python) covering Terraform, CloudFormation, Dockerfiles, and Kubernetes manifests. It has more rules but is slower. Running both gives better coverage — tfsec catches many AWS-specific misconfigs quickly, checkov catches things tfsec misses (like ECS read-only root filesystem, S3 access logging). Results are uploaded as SARIF to GitHub's Security tab for tracking.

---

**Q: What is SARIF and why is it the preferred output format for security scanners?**

SARIF (Static Analysis Results Interchange Format) is a standardized JSON format for security scanner output, defined by OASIS. GitHub natively reads SARIF files and integrates them into: Code Scanning alerts (Security tab), PR annotations (inline diff comments at the specific line), and alert lifecycle tracking (open, dismissed, fixed). Without SARIF, you'd get raw text output in logs that disappears after the run. SARIF output persists, can be filtered, and gives a historical view of security findings.

---

*See also: DEVOPS_NOTES.md (Docker/GitHub Actions CI basics), TERRAFORM_NOTES.md (Terraform concepts), OBSERVABILITY_NOTES.md (Prometheus/Grafana/EFK)*

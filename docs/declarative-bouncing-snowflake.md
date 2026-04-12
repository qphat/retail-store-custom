# Plan: CI/CD for ECS Fargate + Terraform (Production-Grade)

## Context

Existing `ci.yml` builds/scans/pushes Docker images. New Terraform ECS Fargate infra exists but has no automation. Need two new workflows + fixes to the existing one.

User feedback addressed:
- Proper task definition update (not `--force-new-deployment` + `:latest`)
- Use specific SHA tag in task def, not `:latest`
- OIDC instead of long-lived AWS credentials
- State lock + concurrency guard (no race conditions)
- Plan runs for correct env (not always dev), staging/prod require approval
- Race condition protection between concurrent CI/CD runs
- HTTP health check after ECS deploy
- Terraform cache for faster CI
- `terraform fmt -check` + `terraform validate` on PRs
- Retry on ECS deploy failure
- Tag ECS resources with deploy metadata

---

## Architecture

```
PR opened (terraform/** changed)
  → terraform.yml: detect env → fmt + validate + plan (per env) → PR comment

PR merged to main
  → terraform.yml: apply dev (auto) → apply staging (manual approval) → apply prod (manual approval)
  → ci.yml: detect changed services → build → scan → push :{sha} + :latest
         → deploy: update task def with :{sha} → update service → wait stable → HTTP health check

Concurrency guards:
  terraform: group=terraform-{env}         (queued, not cancelled)
  ecs deploy: group=ecs-deploy-{service}   (queued, not cancelled)
```

---

## Files to create / modify

| File | Action |
|---|---|
| `.gitignore` | Add `!terraform/environments/*/terraform.tfvars` exception |
| `terraform/global/main.tf` | NEW — OIDC provider + GitHub Actions IAM role |
| `terraform/global/outputs.tf` | NEW — role ARN output |
| `.github/workflows/terraform.yml` | NEW |
| `.github/workflows/ci.yml` | ADD `deploy` job |

---

## 1. `.gitignore` fix

```gitignore
*.tfvars
!terraform/environments/*/terraform.tfvars
```

Reason: tfvars contain no secrets (only cpu/memory sizing). Without committing them, GitHub Actions can't run `terraform plan` correctly.

---

## 2. `terraform/global/` — OIDC + IAM Role (run once manually)

**`terraform/global/main.tf`:**
```hcl
# GitHub OIDC provider — allows GitHub Actions to assume AWS roles
# without storing long-lived AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-retail-store"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:qphat/retail-store-custom:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Permissions: ECS deploy + Terraform state + ECR + SSM
resource "aws_iam_role_policy" "github_actions" {
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Terraform state backend
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::retail-store-tf-state-*", "arn:aws:s3:::retail-store-tf-state-*/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/retail-store-tf-lock"
      },
      # ECS deploy
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition",
                    "ecs:UpdateService", "ecs:DescribeServices",
                    "ecs:ListTaskDefinitions"]
        Resource = "*"
      },
      # ELB (health check — describe ALB DNS)
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers"]
        Resource = "*"
      },
      # IAM PassRole (needed to register task definition)
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/*-execution-role"
      },
      # Full infra permissions for terraform apply
      { Effect = "Allow", Action = ["ec2:*", "ecs:*", "iam:*", "logs:*",
                                     "ssm:*", "elasticloadbalancing:*",
                                     "servicediscovery:*", "route53:*"]
        Resource = "*" }
    ]
  })
}
```

**`terraform/global/outputs.tf`:**
```hcl
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
```

**Setup:** Run once manually:
```bash
cd terraform/global && terraform init && terraform apply
# Copy output role ARN → set as GitHub var AWS_ROLE_ARN
```

---

## 3. `.github/workflows/terraform.yml` — NEW

### Triggers
```yaml
on:
  pull_request:
    branches: [main]
    paths: ['terraform/**']
  push:
    branches: [main]
    paths: ['terraform/**']
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]
        required: true
```

### Concurrency (prevents two terraform runs at same time per env)
```yaml
concurrency:
  group: terraform-${{ github.event.inputs.environment || 'dev' }}
  cancel-in-progress: false   # queue, don't cancel — avoids partial applies
```

### Job: `lint` (PRs only — fast feedback)
```yaml
steps:
  - terraform fmt -check -recursive terraform/
  - For each changed env:
      terraform init -backend=false   # skip backend for validate
      terraform validate
```

### Job: `plan` (PRs only, per changed environment)
```yaml
strategy:
  matrix:
    environment: [detected changed envs via paths-filter]

steps:
  - configure-aws-credentials (OIDC, role-to-assume: ${{ vars.AWS_ROLE_ARN }})
  - hashicorp/setup-terraform@v3
  - Cache: ~/.terraform.d/plugin-cache keyed on .terraform.lock.hcl hash
  - cd terraform/environments/${{ matrix.environment }}
  - terraform init -lock-timeout=5m
  - terraform plan -no-color -lock-timeout=5m -out=tfplan
  - Upload tfplan as artifact (for apply job to reuse)
  - Post plan output as PR comment (peter-evans/create-or-update-comment)
    - Update existing comment if re-running on same PR
    - Show collapsible <details> block with full plan
```

### Job: `apply-dev` (push to main, auto — no approval)
```yaml
environment: dev
needs: []   # runs directly on push to main
steps:
  - configure-aws-credentials (OIDC)
  - setup-terraform + cache
  - cd terraform/environments/dev
  - terraform init -lock-timeout=5m
  - terraform apply -auto-approve -lock-timeout=5m
```

### Job: `apply-staging` (workflow_dispatch, requires GitHub Environment approval)
```yaml
environment: staging   # GitHub Environment — configure required reviewers in repo settings
if: github.event_name == 'workflow_dispatch' && inputs.environment == 'staging'
steps: same pattern as apply-dev
```

### Job: `apply-prod` (workflow_dispatch, requires approval)
```yaml
environment: prod   # strictest — configure multiple required reviewers
if: github.event_name == 'workflow_dispatch' && inputs.environment == 'prod'
steps: same pattern
```

### GitHub Environments to configure in repo settings:
- `dev` — no protection rules (auto-applies)
- `staging` — required reviewers: [koomi]
- `prod` — required reviewers: [koomi], wait timer: 5 min

---

## 4. `.github/workflows/ci.yml` — ADD `deploy` job

### Key changes from original plan:

**Use specific SHA tag, not `:latest`**
- Task definition registers `koomi1/retail-app-catalog:{github.sha}`
- ECS pulls exact image — reproducible, auditable, rollback-friendly
- `:latest` still pushed to Docker Hub (for local `docker pull`) but NOT used in ECS

**Proper task definition update (not `--force-new-deployment`)**
```yaml
# Step 1: Download current task definition JSON
aws ecs describe-task-definition \
  --task-definition dev-${{ matrix.service }} \
  --query taskDefinition > task-def.json

# Step 2: Update container image in the JSON (using aws-actions/amazon-ecs-render-task-definition)
uses: aws-actions/amazon-ecs-render-task-definition@v1
with:
  task-definition: task-def.json
  container-name: ${{ matrix.service }}
  image: ${{ vars.IMAGE_PREFIX }}-${{ matrix.service }}:${{ github.sha }}

# Step 3: Register new task definition revision + update ECS service
uses: aws-actions/amazon-ecs-deploy-task-definition@v2
with:
  task-definition: task-def-updated.json
  service: dev-${{ matrix.service }}
  cluster: dev-retail-store
  wait-for-service-stability: true
  wait-for-minutes: 10
```

**Why update task definition:**
- Creates a new revision (e.g. `dev-catalog:5`) — full audit trail
- Each revision pinned to a specific SHA — safe rollback: `aws ecs update-service --task-definition dev-catalog:4`
- `--force-new-deployment` + `:latest` is unpredictable — can redeploy the WRONG image if a newer push happened

**Concurrency (race condition protection)**
```yaml
concurrency:
  group: ecs-deploy-${{ matrix.service }}
  cancel-in-progress: false   # second deploy waits, doesn't cancel first
```

**Retry on transient ECS failures**
```yaml
- name: Deploy to ECS
  uses: nick-fields/retry@v3
  with:
    timeout_minutes: 15
    max_attempts: 3
    retry_wait_seconds: 30
    command: |
      # render + deploy steps here
```

**HTTP health check after deploy**
```yaml
- name: Health check via ALB
  run: |
    ALB=$(aws elbv2 describe-load-balancers \
      --names dev-retail-store \
      --query 'LoadBalancers[0].DNSName' \
      --output text)

    HEALTH_PATH="${{ matrix.health_path }}"   # /health or /actuator/health
    URL="http://$ALB$HEALTH_PATH"

    echo "Checking $URL ..."
    for i in $(seq 1 10); do
      if curl -sf --max-time 5 "$URL"; then
        echo "Health check passed on attempt $i"
        exit 0
      fi
      echo "Attempt $i failed — waiting 15s..."
      sleep 15
    done
    echo "Health check failed after 10 attempts"
    exit 1
```

**Tag ECS task definition with deploy metadata**
In the rendered task definition JSON, add tags before registering:
```yaml
- name: Tag task definition
  run: |
    jq '.tags += [
      {"key": "GitSHA",    "value": "${{ github.sha }}"},
      {"key": "RunID",     "value": "${{ github.run_id }}"},
      {"key": "DeployedBy","value": "github-actions"}
    ]' task-def.json > task-def-tagged.json
```

**Health path per service** (add to matrix.include in detect job):
```yaml
include:
  - service: catalog
    health_path: /health
  - service: ui
    health_path: /actuator/health
  - service: cart
    health_path: /actuator/health
  - service: orders
    health_path: /actuator/health
  - service: checkout
    health_path: /health
```

---

## GitHub secrets / vars needed

| Name | Type | Value |
|---|---|---|
| `AWS_ROLE_ARN` | Variable | ARN from `terraform/global` output |
| `AWS_REGION` | Variable | `us-east-1` |

Remove (no longer needed after OIDC):
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Existing (keep):
- `DOCKER_USERNAME`, `DOCKER_PASSWORD`
- `DOCKER_REGISTRY`, `IMAGE_PREFIX`

---

---

## 5. tfsec + checkov — Terraform Security Scanning on PRs

Add as a parallel job in `terraform.yml` alongside `lint` — runs on every PR touching `terraform/**`.

### Job: `security-scan`
```yaml
security-scan:
  name: Terraform Security Scan
  runs-on: ubuntu-latest
  if: github.event_name == 'pull_request'
  steps:
    - uses: actions/checkout@v4

    # tfsec — HashiCorp-aware, fast, good AWS rule set
    - name: Run tfsec
      uses: aquasecurity/tfsec-action@v1
      with:
        working_directory: terraform/
        soft_fail: false          # fail PR on HIGH/CRITICAL findings
        format: sarif             # upload to GitHub Security tab
        github_token: ${{ secrets.GITHUB_TOKEN }}

    # checkov — broader policy engine, catches misconfigs tfsec misses
    - name: Run checkov
      uses: bridgecrewio/checkov-action@v12
      with:
        directory: terraform/
        framework: terraform
        soft_fail: false
        output_format: sarif
        output_file_path: checkov-results.sarif

    - name: Upload checkov SARIF
      uses: github/codeql-action/upload-sarif@v3
      if: always()               # upload even if checkov fails
      with:
        sarif_file: checkov-results.sarif
```

**What they catch:**
| Tool | Examples for this project |
|---|---|
| tfsec | Security group `0.0.0.0/0` egress, unencrypted CloudWatch logs, missing ALB access logs |
| checkov | IAM `*` resource in policies, missing S3 bucket versioning, ECS task without read-only root fs |

**Suppressions** (expected findings to ignore):
```hcl
# In modules/ecs-service/main.tf — ALB allows 0.0.0.0/0 by design
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
resource "aws_security_group" "alb" { ... }
```

---

## 6. Health Check Spread Across All Microservices

### Problem with current single-service health check
After ECS marks a service stable, the ALB health check only verifies one task is healthy.
We need to verify ALL 5 services respond correctly through the ALB — a cascading failure
(e.g. ui is up but catalog is broken) would pass a single-service check.

### Separate job: `smoke-test` (runs after all deploy jobs complete)

```yaml
smoke-test:
  name: Smoke Test — All Services
  runs-on: ubuntu-latest
  needs: deploy          # waits for all matrix deploy jobs
  if: github.event_name == 'push'
  steps:
    - uses: actions/checkout@v4

    - name: Configure AWS credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${{ vars.AWS_ROLE_ARN }}
        aws-region: ${{ vars.AWS_REGION }}

    - name: Get ALB DNS
      id: alb
      run: |
        DNS=$(aws elbv2 describe-load-balancers \
          --names dev-retail-store \
          --query 'LoadBalancers[0].DNSName' \
          --output text)
        echo "dns=$DNS" >> $GITHUB_OUTPUT

    - name: Smoke test all services
      run: |
        BASE="http://${{ steps.alb.outputs.dns }}"
        FAILED=0

        check() {
          local name=$1
          local url=$2
          local expected=$3   # expected HTTP status code

          for i in $(seq 1 5); do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url")
            if [ "$STATUS" = "$expected" ]; then
              echo "✓ $name — $url → $STATUS"
              return 0
            fi
            echo "  attempt $i: $name got $STATUS, expected $expected"
            sleep 10
          done

          echo "✗ $name FAILED after 5 attempts"
          FAILED=$((FAILED + 1))
        }

        # Each service, its ALB path, and expected HTTP status
        check "ui"       "$BASE/"                    "200"
        check "catalog"  "$BASE/catalogue"           "200"
        check "cart"     "$BASE/api/cart/health"     "200"
        check "checkout" "$BASE/api/checkout/health" "200"
        check "orders"   "$BASE/api/orders/health"   "200"
        check "kibana"   "$BASE/kibana/api/status"   "200"

        if [ $FAILED -gt 0 ]; then
          echo "$FAILED service(s) failed smoke test"
          exit 1
        fi
        echo "All services healthy"
```

**Why separate from per-service health check:**
- Per-service check (in `deploy` job): verifies THIS service started correctly
- Smoke test (in `smoke-test` job): verifies ALL services work TOGETHER through the ALB
  - Catches: ALB listener rule conflicts, inter-service DNS resolution failures,
    environment variable misconfigs (e.g. ui can't reach catalog)
  - Runs once after all deploys finish, not per-service

---

## 7. Drift Detection — `terraform-drift.yml` (scheduled)

Separate workflow, runs on cron. Detects when someone manually changes AWS resources
outside Terraform (console clicks, manual `aws` CLI commands).

**File: `.github/workflows/terraform-drift.yml`**

```yaml
name: Terraform Drift Detection

on:
  schedule:
    - cron: '0 6 * * 1-5'    # 6am UTC weekdays (1pm Vietnam time)
  workflow_dispatch:           # also runnable manually

permissions:
  contents: read
  id-token: write             # OIDC
  issues: write               # to open a GitHub Issue on drift

jobs:
  detect-drift:
    name: Drift — ${{ matrix.environment }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false        # check all envs even if dev has drift
      matrix:
        environment: [dev, staging, prod]

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: hashicorp/setup-terraform@v3

      - name: Cache Terraform plugins
        uses: actions/cache@v4
        with:
          path: ~/.terraform.d/plugin-cache
          key: terraform-${{ runner.os }}-${{ hashFiles('**/.terraform.lock.hcl') }}

      - name: Terraform init
        working-directory: terraform/environments/${{ matrix.environment }}
        run: terraform init -lock-timeout=2m

      - name: Terraform plan (drift check)
        id: plan
        working-directory: terraform/environments/${{ matrix.environment }}
        run: |
          # -detailed-exitcode: exits 0=no changes, 1=error, 2=changes detected
          terraform plan \
            -detailed-exitcode \
            -lock=false \           # read-only, don't lock state
            -refresh=true \         # fetch real AWS state
            -no-color \
            -out=drift.tfplan 2>&1 | tee plan.txt

          EXIT_CODE=${PIPESTATUS[0]}
          echo "exit_code=$EXIT_CODE" >> $GITHUB_OUTPUT

          if [ $EXIT_CODE -eq 2 ]; then
            echo "has_drift=true" >> $GITHUB_OUTPUT
            echo "DRIFT DETECTED in ${{ matrix.environment }}"
          elif [ $EXIT_CODE -eq 0 ]; then
            echo "has_drift=false" >> $GITHUB_OUTPUT
            echo "No drift in ${{ matrix.environment }}"
          else
            echo "Plan failed (error)"
            exit 1
          fi

      - name: Upload drift plan artifact
        if: steps.plan.outputs.has_drift == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: drift-${{ matrix.environment }}-${{ github.run_id }}
          path: terraform/environments/${{ matrix.environment }}/plan.txt
          retention-days: 7

      - name: Open GitHub Issue on drift
        if: steps.plan.outputs.has_drift == 'true'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync(
              'terraform/environments/${{ matrix.environment }}/plan.txt', 'utf8'
            ).slice(0, 4000);  // GitHub issue body limit

            // Check if a drift issue already exists for this env
            const issues = await github.rest.issues.listForRepo({
              owner: context.repo.owner,
              repo: context.repo.repo,
              state: 'open',
              labels: ['terraform-drift', '${{ matrix.environment }}']
            });

            const title = `[Drift] Terraform drift detected in ${{ matrix.environment }}`;
            const body = [
              `## Terraform Drift Detected — \`${{ matrix.environment }}\``,
              ``,
              `Detected at: ${new Date().toISOString()}`,
              `Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`,
              ``,
              `\`\`\``,
              plan,
              `\`\`\``,
              ``,
              `**To fix:** Run \`terraform apply\` or investigate the manual change.`,
            ].join('\n');

            if (issues.data.length === 0) {
              await github.rest.issues.create({
                owner: context.repo.owner,
                repo: context.repo.repo,
                title,
                body,
                labels: ['terraform-drift', '${{ matrix.environment }}']
              });
            } else {
              // Update existing issue instead of creating duplicate
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: issues.data[0].number,
                body: `## New drift detected — ${new Date().toISOString()}\n\n\`\`\`\n${plan}\n\`\`\``
              });
            }

  summary:
    name: Drift Summary
    runs-on: ubuntu-latest
    needs: detect-drift
    if: always()
    steps:
      - name: Report
        run: |
          echo "Drift detection complete."
          echo "Check GitHub Issues with label 'terraform-drift' for details."
```

**`-lock=false` on drift plan:** Drift check is read-only — it refreshes state from AWS but doesn't write. No lock needed. Avoids blocking real applies.

**`-detailed-exitcode`:** Standard pattern for drift detection:
- `0` = plan empty (no drift)
- `1` = error
- `2` = changes detected (drift!)

**GitHub Issue strategy:**
- New drift → create Issue with label `terraform-drift` + env label
- Drift persists next day → add comment to existing Issue (no duplicates)
- Issue closes when someone runs `terraform apply`

---

## What's NOT in this plan (future)

- **Infracost** — cost diff comment on Terraform PRs
- **Rollback job** — on smoke-test failure, revert ECS service to previous task def revision
- **Slack notifications** — on drift issue / deploy failure
- **PR ephemeral environments** — spin up per-PR ECS env, destroy on PR close

---

## Verification

1. Open a PR changing `terraform/modules/vpc/main.tf` → confirm plan comment appears on PR
2. Change `terraform/environments/staging/terraform.tfvars` → confirm plan runs for staging env
3. Merge terraform PR → confirm `apply-dev` job runs automatically
4. Trigger `workflow_dispatch` with `environment=staging` → confirm approval gate appears
5. Push a code change to `src/catalog/` → confirm:
   - New task definition revision registered (e.g. `dev-catalog:N+1`)
   - ECS service updated to new revision
   - `aws ecs wait services-stable` completes
   - HTTP health check passes
6. Push two simultaneous commits → confirm second deploy queues (not cancels) behind first

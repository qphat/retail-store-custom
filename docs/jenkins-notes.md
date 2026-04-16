# Jenkins CI/CD — Learning Notes & Interview Q&A

> Based on the retail-store-sample-app Jenkins pipeline (`feat/eks` branch, `Jenkinsfile`).
> Covers: what Jenkins is, why it exists, how it compares to GitHub Actions,
> how we implemented it with Terraform, pipeline design, and interview Q&A.

---

## Table of Contents

1. [What is Jenkins?](#1-what-is-jenkins)
2. [Jenkins vs GitHub Actions — When to Use Which](#2-jenkins-vs-github-actions--when-to-use-which)
3. [Jenkins Architecture](#3-jenkins-architecture)
4. [How We Set It Up — Terraform on EC2](#4-how-we-set-it-up--terraform-on-ec2)
5. [Declarative Pipeline — Jenkinsfile Concepts](#5-declarative-pipeline--jenkinsfile-concepts)
6. [Change Detection (No dorny/paths-filter)](#6-change-detection-no-dornypaths-filter)
7. [Parallel Builds + Concurrency Guard](#7-parallel-builds--concurrency-guard)
8. [AWS Auth — EC2 IAM Role vs Static Keys](#8-aws-auth--ec2-iam-role-vs-static-keys)
9. [Image Tagging Strategy — SHA Only, No :latest](#9-image-tagging-strategy--sha-only-no-latest)
10. [Deploy to EKS via Helm](#10-deploy-to-eks-via-helm)
11. [Smoke Test + Retry Logic](#11-smoke-test--retry-logic)
12. [Terraform Stage with Approval Gate](#12-terraform-stage-with-approval-gate)
13. [GitHub Actions vs Jenkins — Full Side-by-Side](#13-github-actions-vs-jenkins--full-side-by-side)
14. [Interview Q&A](#14-interview-qa)

---

## 1. What is Jenkins?

**Jenkins** is an open-source automation server written in Java.
It runs pipelines — sequences of steps for building, testing, scanning, and deploying software.

```
Developer pushes code
    │ webhook / polling
    ▼
Jenkins Controller
    ├── Checkout code from Git
    ├── Build Docker image
    ├── Run security scan (Trivy)
    ├── Push image to registry
    ├── Deploy to EKS (Helm)
    └── Run smoke test
```

Key facts:
- Released in 2011 (forked from Hudson, originally at Sun Microsystems)
- Self-hosted — you run it on your own server (EC2, VM, bare metal, or K8s)
- 1,800+ plugins — integrates with almost any tool
- Pipeline-as-code via `Jenkinsfile` (stored in the repo, versioned with the app)
- Free and open-source

---

## 2. Jenkins vs GitHub Actions — When to Use Which

This project implements **both** — same pipeline logic, different platforms.

### Why companies still use Jenkins in 2025

| Reason | Detail |
|---|---|
| **Enterprise legacy** | Thousands of existing Jenkinsfiles — migration cost is too high |
| **Air-gapped environments** | No internet access → can't use GitHub's cloud runners |
| **Custom agents** | Need specialized hardware (GPU, HSM, specific OS) |
| **Complex approval workflows** | Multi-team sign-off before prod deploy |
| **Cost at scale** | GitHub Actions charges per minute on private repos; Jenkins uses your own EC2 |
| **On-premises compliance** | Some industries (banking, defence) can't push code to cloud CI |

### When GitHub Actions is better

| Reason | Detail |
|---|---|
| **No infra to maintain** | No EC2, no Jenkins updates, no disk-full issues |
| **OIDC natively supported** | Zero-credential AWS auth out of the box |
| **Simpler for small teams** | No plugin management, no controller HA to set up |
| **Matrix builds** | Native, no extra plugins needed |
| **GitHub-native** | PR comments, checks API, Dependabot integration |

### Decision rule of thumb

```
New greenfield project + GitHub repo → GitHub Actions
Enterprise with existing Jenkinsfile + on-prem → Jenkins
Need both (portfolio / interview demo) → implement both
```

---

## 3. Jenkins Architecture

### Components

```
┌─────────────────────────────────────────────┐
│              Jenkins Controller              │
│  - Web UI (port 8080)                        │
│  - Job scheduler                             │
│  - Plugin host                               │
│  - Build queue                               │
│  - Credentials store                         │
└──────────────────┬──────────────────────────┘
                   │ JNLP (port 50000) or SSH
         ┌─────────┴──────────┐
         ▼                    ▼
   Agent Node 1         Agent Node 2
   (builds run here)    (builds run here)
```

In this project: single-node setup — controller and agent are the same EC2 instance
(`agent any` in Jenkinsfile). Sufficient for a learning/dev environment.

### Key concepts

| Term | What it is |
|---|---|
| **Controller** | The Jenkins server — schedules builds, stores config, serves UI |
| **Agent** | Machine that executes pipeline steps (can be the controller itself) |
| **Executor** | Thread slot on an agent — how many builds can run simultaneously |
| **Job / Project** | A configured pipeline or freestyle task |
| **Build** | One execution of a job |
| **Stage** | A named block of steps — shown as a column in Blue Ocean UI |
| **Step** | A single action (sh, echo, archiveArtifacts, input, lock...) |
| **Credentials** | Secrets stored in Jenkins — passwords, tokens, SSH keys, files |
| **Plugin** | Extension that adds capabilities (Docker, AWS, Lockable Resources...) |

### Multibranch Pipeline

This project uses a **Multibranch Pipeline** job type.

```
Jenkins scans GitHub repo → finds branches with a Jenkinsfile
  main      → creates pipeline job "retail-store/main"
  feat/eks  → creates pipeline job "retail-store/feat/eks"
  PR #12    → creates pipeline job "retail-store/PR-12"
```

Each branch gets its own build history and can have different `when {}` conditions
(e.g. deploy only on `main`, scan on all branches).

---

## 4. How We Set It Up — Terraform on EC2

### Why Terraform for Jenkins? (not manual)

Manual setup is:
- Not reproducible (next time = start from scratch)
- Not version-controlled (no history of what changed)
- Error-prone (missed step = debugging for hours)

With Terraform:
```bash
terraform apply      # Jenkins EC2 is created + fully configured
terraform destroy    # Jenkins is gone, no residual costs
```

Everything is code: instance type, IAM role, security group, tools installed.

### What Terraform creates (`terraform/modules/jenkins/`)

```
aws_instance.jenkins
  └── ubuntu 22.04 t3.medium
  └── user_data.sh (runs at first boot)
      ├── apt-get install jenkins docker.io openjdk-21-jdk
      ├── usermod -aG docker jenkins
      ├── install aws cli, kubectl, helm, trivy, terraform
      └── aws eks update-kubeconfig → /var/lib/jenkins/.kube/config

aws_iam_role.jenkins
  └── EC2 instance profile (no static credentials)
  └── Permissions: EKS describe, ECR push/pull, S3/DynamoDB (terraform state),
                   ECS deploy (optional)

aws_security_group.jenkins
  └── Ingress 8080: Jenkins UI (your IP only)
  └── Ingress 22:   SSH (your IP only)
  └── Egress all

aws_eip.jenkins
  └── Stable public IP (doesn't change on stop/start)
```

### `user_data.sh` — bootstrap at first boot

`user_data.sh` is a shell script that EC2 runs exactly once on the first boot.
It installs every tool Jenkins needs so the instance is fully ready with no manual SSH.

```bash
# Critical steps in order:
1. apt-get install docker.io jenkins openjdk-21-jdk
2. usermod -aG docker jenkins        ← without this, docker build fails
3. install aws cli, kubectl, helm, trivy, terraform
4. aws eks update-kubeconfig          ← pre-configures kubectl for jenkins user
5. systemctl enable jenkins && systemctl start jenkins
```

After `terraform apply`: wait 2-3 minutes, then `http://<EIP>:8080` is live.

### Post-apply commands

```bash
# Get Jenkins URL
terraform output jenkins_url

# Get initial admin password
terraform output jenkins_initial_password
# Run the printed SSH command → copy 32-char password → paste into browser
```

---

## 5. Declarative Pipeline — Jenkinsfile Concepts

Jenkins has two pipeline syntaxes. We use **Declarative** (recommended):

```
Declarative (our choice)        Scripted (older)
─────────────────────────       ─────────────────
pipeline { ... }                node { ... }
Structured, readable            Pure Groovy, flexible but verbose
Validates syntax before run     No pre-validation
Best for CI/CD pipelines        Best for complex scripting logic
```

### Jenkinsfile skeleton

```groovy
pipeline {
    agent any                     // run on any available agent

    environment {                 // env vars available to all stages
        IMAGE_PREFIX = 'koomi1/retail-app'
    }

    options {
        timestamps()              // add timestamps to log
        ansiColor('xterm')        // colour output
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {                  // expose inputs for manual runs
        choice(name: 'TF_ENV', choices: ['none', 'eks-dev'])
    }

    stages {

        stage('Build') {
            when { branch 'main' }           // condition to run this stage
            steps {
                sh 'docker build ...'         // shell command
                script { /* Groovy logic */ } // scripted block inside declarative
            }
        }

        stage('Parallel Work') {
            parallel {                        // run sub-stages simultaneously
                stage('A') { steps { sh '...' } }
                stage('B') { steps { sh '...' } }
            }
        }

    }

    post {                        // always runs, even on failure
        success { echo 'Done' }
        failure { echo 'Failed' }
        always  { sh 'docker image prune -f || true' }
    }
}
```

### Key built-in steps

| Step | What it does |
|---|---|
| `sh 'command'` | Run a shell command |
| `sh(script: '...', returnStdout: true)` | Capture command output as string |
| `script { }` | Groovy code block inside Declarative |
| `env.VAR = 'value'` | Set env var dynamically |
| `withCredentials([...]) { }` | Inject credentials into a block |
| `archiveArtifacts 'path/**'` | Save files to build artifacts |
| `input message: '...', ok: 'Go'` | Pause and wait for human approval |
| `retry(3) { }` | Retry block up to N times on failure |
| `lock(resource: 'name') { }` | Exclusive lock — only one build at a time |
| `timeout(time: 5, unit: 'MINUTES') { }` | Fail if block takes too long |
| `parallel { stage('A') {...} }` | Run stages simultaneously |

---

## 6. Change Detection (No dorny/paths-filter)

GitHub Actions has the `dorny/paths-filter` action.
Jenkins has no equivalent built-in — we use `git diff` scripting.

### How we do it

```groovy
stage('Detect Changes') {
    steps {
        script {
            // Get the previous commit SHA
            def base = sh(
                script: 'git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD',
                returnStdout: true
            ).trim()

            // For each service: count changed files in its directory
            ['catalog', 'cart', 'orders', 'checkout', 'ui'].each { svc ->
                def count = sh(
                    script: "git diff --name-only ${base} HEAD -- src/${svc}/ helm/ | wc -l",
                    returnStdout: true
                ).trim().toInteger()

                // Set environment variable: BUILD_CATALOG=true/false
                env["BUILD_${svc.toUpperCase()}"] = count > 0 ? 'true' : 'false'
            }
        }
    }
}
```

### Using the result in later stages

```groovy
stage('catalog') {
    when { environment name: 'BUILD_CATALOG', value: 'true' }
    steps { ... }
}
```

`when { environment }` skips the stage entirely if the condition is false —
same as the `if:` guard in GitHub Actions matrix jobs.

### Edge case: first commit

`git rev-parse HEAD~1` fails if there is no previous commit (first push to branch).
The `2>/dev/null || git rev-parse HEAD` fallback handles this — compares HEAD to itself,
which returns 0 changed files → all services are treated as unchanged on the very first run.
For the first deploy, use `workflow_dispatch` / manual build to force all services.

---

## 7. Parallel Builds + Concurrency Guard

### Parallel stages

```groovy
stage('Build & Scan') {
    parallel {
        stage('catalog')  { when {...} steps { buildScanPush('catalog')  } }
        stage('cart')     { when {...} steps { buildScanPush('cart')     } }
        stage('orders')   { when {...} steps { buildScanPush('orders')   } }
        stage('checkout') { when {...} steps { buildScanPush('checkout') } }
        stage('ui')       { when {...} steps { buildScanPush('ui')       } }
    }
}
```

All five build/scan/push operations run simultaneously on the same EC2 agent
(limited by CPU/memory). Each is independently guarded by `when {}` — only changed
services actually execute.

GitHub Actions equivalent: `strategy: matrix` + `if: needs.detect.outputs.services`

### Concurrency guard with `lock()`

Problem: Two pushes arrive 30 seconds apart.
Without a lock: both `helm upgrade` commands run simultaneously → race condition,
second may overwrite first's image tag, state becomes undefined.

```groovy
stage('Deploy to EKS') {
    options {
        lock(resource: 'eks-deploy', inversePrecedence: false)
    }
    steps {
        sh 'helm upgrade --install retail-store ...'
    }
}
```

`inversePrecedence: false` = queue (FIFO). First deploy runs, second waits.
After first finishes, second runs with its own (newer) SHA tag.

GitHub Actions equivalent: `concurrency: cancel-in-progress: false`

**Requires:** Lockable Resources plugin installed in Jenkins.

---

## 8. AWS Auth — EC2 IAM Role vs Static Keys

### The wrong way (never do this)

```groovy
// BAD — credentials in Jenkinsfile or Jenkins env
environment {
    AWS_ACCESS_KEY_ID     = 'AKIAIOSFODNN7EXAMPLE'   // ← visible in logs!
    AWS_SECRET_ACCESS_KEY = 'wJalrXUtnFEMI...'
}
```

Problems:
- Keys can expire, rotate, or be revoked — pipeline breaks
- If keys leak (repo, logs, Slack), attacker has AWS access
- You have to update keys in every pipeline that uses them

### The right way — EC2 Instance Profile (IAM Role)

The Jenkins EC2 has an **IAM Instance Profile** attached.
AWS CLI / SDK on the instance automatically uses the role:

```
Jenkins EC2 makes AWS API call
    → SDK checks: is there an instance metadata service (IMDS)?
    → Yes: GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
    → Returns: temporary credentials (rotated every 6 hours by AWS)
    → API call succeeds
No credential configuration needed in Jenkins.
```

In the `Jenkinsfile`:
```groovy
// This just works — no credentials configured
sh 'aws eks update-kubeconfig --name eks-dev-retail-store --region us-east-1'
sh 'aws ecs describe-task-definition --task-definition dev-catalog'
```

### GitHub Actions equivalent

GitHub Actions uses **OIDC** (OpenID Connect) — GitHub's identity provider vouches for
the workflow, AWS trusts it and issues temporary credentials.
Both OIDC and EC2 Instance Profile achieve the same thing: **no long-lived keys stored anywhere**.

| Feature | EC2 IAM Role | GitHub Actions OIDC |
|---|---|---|
| Credential rotation | AWS rotates every 6h | Per-job token, expires after job |
| Where config lives | IAM trust policy + instance profile | IAM trust policy + workflow yaml |
| Can be revoked | Yes (detach role) | Yes (delete IAM role) |
| Works offline | Yes | No (needs GitHub token endpoint) |

---

## 9. Image Tagging Strategy — SHA Only, No :latest

### What we do

```groovy
def image = "${env.IMAGE_PREFIX}-${service}:${env.GIT_COMMIT}"
sh "docker build -t ${image} src/${service}/"
sh "docker push ${image}"
// No :latest tag pushed
```

### Why no :latest

| Problem with :latest | Why it matters |
|---|---|
| Ambiguous | `docker pull koomi1/retail-app-catalog:latest` today ≠ tomorrow |
| Unpredictable rollback | Which version is `:latest`? Depends on last push |
| Race condition | Two pipelines push simultaneously — one overwrites the other's `:latest` |
| No audit trail | You can't tell from `:latest` which commit or pipeline run produced it |

### Why SHA tag

```
koomi1/retail-app-catalog:3a7f2b1
                            ↑
                   git commit SHA (first 40 chars of full SHA)

Benefits:
- Immutable: this tag always means this exact commit
- Traceable: git log 3a7f2b1 shows you exactly what changed
- Safe rollback: helm upgrade --set imageTag=3a7f2b1 (previous SHA)
- Auditable: ECS/K8s logs show which commit is running
```

### Helm deploy uses the same SHA

```groovy
sh "helm upgrade --install retail-store helm/retail-store --set imageTag=${GIT_COMMIT}"
```

The Helm chart uses `{{ .Values.imageTag }}` in the Deployment template —
every pod runs the exact image that was built and scanned in this pipeline run.

---

## 10. Deploy to EKS via Helm

### How it works

```groovy
stage('Deploy to EKS') {
    when { anyOf { branch 'main'; branch 'feat/eks' } }
    options { lock(resource: 'eks-deploy', inversePrecedence: false) }
    steps {
        // Step 1: Get cluster credentials (IAM role handles auth)
        sh 'aws eks update-kubeconfig --name eks-dev-retail-store --region us-east-1'

        // Step 2: NGINX ingress controller (idempotent)
        sh '''
            helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
              --namespace ingress-nginx --create-namespace \
              --set controller.service.type=LoadBalancer \
              --wait --timeout 5m
        '''

        // Step 3: App deploy — SHA tag pinned
        sh '''
            helm upgrade --install retail-store helm/retail-store \
              --set imageTag=${GIT_COMMIT} \
              --set imageRegistry=${IMAGE_REGISTRY} \
              --wait --timeout 10m
        '''
    }
}
```

### `helm upgrade --install` — why not `helm install`

`helm install` fails if the release already exists.
`helm upgrade --install` creates on first run, updates on subsequent runs.
It's **idempotent** — safe to run on every push.

### `--wait` flag

Helm waits until all pods are `Running` and `Ready` before returning.
If pods don't become ready within `--timeout`, Helm marks the release as failed
and the pipeline step fails → you see the failure immediately rather than deploying
a broken release silently.

### Why deploy NGINX ingress controller on every run

It's idempotent (`upgrade --install`) — if it's already up to date, Helm does nothing.
This ensures the ingress controller is always present even if someone accidentally
deleted it. Same pattern as GitOps continuous reconciliation.

---

## 11. Smoke Test + Retry Logic

### Why a smoke test after deploy

Helm `--wait` only checks that pods are `Running` and `Ready` (readiness probe passes).
It does NOT verify:
- The ALB/NLB has an IP address and DNS is resolving
- The app actually returns HTTP 200 (not a 500 error on startup)
- Inter-service communication works (ui can reach catalog, etc.)

The smoke test catches all of these.

### Retry logic

Network and DNS take time to converge after a new deploy.
The check function retries each endpoint up to 10 times with 15-second gaps (~2.5 min):

```bash
check() {
    local name=$1 url=$2 expected=$3
    for i in $(seq 1 10); do
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || echo "000")
        [ "$STATUS" = "$expected" ] && { echo "✓ $name"; return 0; }
        sleep 15
    done
    echo "✗ $name FAILED"
    FAILED=$((FAILED+1))
}

check "ui"       "$BASE/"                    "200"
check "catalog"  "$BASE/catalogue"           "200"
check "cart"     "$BASE/api/cart/health"     "200"
check "orders"   "$BASE/api/orders/health"   "200"
check "checkout" "$BASE/api/checkout/health" "200"
check "kibana"   "$BASE/kibana/api/status"   "200"

[ $FAILED -gt 0 ] && exit 1
```

If any service fails all 10 attempts, the pipeline fails with a clear message.
The `FAILED` counter accumulates — all services are checked even if one fails earlier,
so you see the full picture in one run.

---

## 12. Terraform Stage with Approval Gate

### Why Terraform in the Jenkins pipeline

- Same pipeline can provision infrastructure AND deploy the app
- Provides a full audit trail: who applied, when, with what plan
- Approval gate prevents accidental prod changes

### Design

```groovy
parameters {
    choice(name: 'TF_ENV',    choices: ['none', 'eks-dev'])
    choice(name: 'TF_ACTION', choices: ['plan', 'apply'])
}

stage('Terraform') {
    when { not { environment name: 'TF_ENV', value: 'none' } }

    stages {
        stage('Lint')  { steps { sh 'terraform fmt -check -recursive' } }
        stage('Plan')  { steps { sh 'terraform plan -out=tfplan' } }
        stage('Apply') {
            when { expression { params.TF_ACTION == 'apply' } }
            steps {
                script {
                    if (params.TF_ENV != 'eks-dev') {
                        // Human must click "Apply" in the Jenkins UI
                        input message: "Apply Terraform to ${params.TF_ENV}?", ok: 'Apply'
                    }
                }
                sh 'terraform apply -auto-approve tfplan'
            }
        }
    }
}
```

### `input` step — how it works

When Jenkins hits `input`, the pipeline **pauses** and shows a button in the UI.
A human clicks "Apply" or "Abort". The pipeline continues or fails accordingly.
This replaces GitHub Actions' **Environment protection rules** (required reviewers).

### Default run (push to main) → Terraform is skipped

`TF_ENV` defaults to `none` → `when { not { environment name: 'TF_ENV', value: 'none' } }` is false → stage skipped.
Only a manual **Build with Parameters** run with `TF_ENV = eks-dev` triggers Terraform.

---

## 13. GitHub Actions vs Jenkins — Full Side-by-Side

| Concept | GitHub Actions | Jenkins |
|---|---|---|
| Pipeline file | `.github/workflows/*.yml` | `Jenkinsfile` |
| Language | YAML | Groovy (Declarative DSL) |
| Hosted by | GitHub (cloud) | Your EC2 (self-hosted) |
| Agent | `runs-on: ubuntu-latest` | `agent any` |
| Change detection | `dorny/paths-filter` action | `git diff --name-only HEAD~1` |
| Matrix / parallel | `strategy: matrix` | `parallel { stage(...) }` |
| Condition | `if: env == 'x'` | `when { environment name: 'x', value: 'y' }` |
| Concurrency guard | `concurrency: cancel-in-progress: false` | `lock(resource: 'name')` |
| AWS auth | OIDC (federated token) | EC2 IAM Instance Profile |
| Secrets | GitHub Secrets | Jenkins Credentials store |
| Retry | `nick-fields/retry` action | `retry(3) { }` (built-in) |
| Manual approval | GitHub Environment gates | `input` step |
| Artifact storage | `actions/upload-artifact` | `archiveArtifacts` |
| Cache | `actions/cache` | Jenkins Cache plugin or volume |
| Plugin ecosystem | GitHub Marketplace | plugins.jenkins.io (~1800 plugins) |
| Cost | Per-minute on private repos | EC2 cost (~$0.05/hr t3.medium) |
| Maintenance | None (GitHub manages) | OS updates, Jenkins upgrades, disk |
| OIDC support | Native | Plugin needed (or use IAM role) |
| PR comments (plan) | `peter-evans/create-or-update-comment` | `publishHTML`, `commentOnPR` plugin |

---

## 14. Interview Q&A

---

### Q1: What is Jenkins and what problem does it solve?

**Answer:**
Jenkins is an open-source CI/CD automation server. It solves the problem of
repeatability and speed in software delivery. Without CI/CD, developers manually
build, test, and deploy — which is slow, error-prone, and inconsistent.

Jenkins automates that process: every push triggers a pipeline that builds the code,
runs tests and security scans, and deploys to the target environment. The same steps
run every time, in the same order, on the same type of machine.

In this project I used Jenkins to mirror our GitHub Actions pipeline — same logic
(detect changes, build Docker images, Trivy scan, Helm deploy to EKS, smoke test),
but running on a self-hosted EC2 instance provisioned by Terraform.

---

### Q2: What is the difference between Declarative and Scripted Pipeline?

**Answer:**
Both are written in Groovy and stored in a `Jenkinsfile`, but they have different syntax.

**Declarative Pipeline** (what we use):
- Structured: `pipeline { agent... stages { stage('X') { steps {...} } } }`
- Validated before run — syntax errors caught immediately
- Opinionated: clear separation between config and logic
- Recommended for standard CI/CD pipelines

**Scripted Pipeline** (older):
- `node { stage('X') { sh '...' } }`
- Pure Groovy — full flexibility
- No pre-validation — errors only appear at runtime
- Better for very complex logic that doesn't fit Declarative

In practice: start with Declarative. Use `script {}` blocks inside Declarative when
you need Groovy logic. Only fall back to Scripted if Declarative genuinely can't
express what you need.

---

### Q3: How does Jenkins handle concurrent builds and prevent race conditions?

**Answer:**
Using the **Lockable Resources plugin** and the `lock()` step.

```groovy
stage('Deploy') {
    options {
        lock(resource: 'eks-deploy', inversePrecedence: false)
    }
    steps { sh 'helm upgrade ...' }
}
```

`inversePrecedence: false` means the queue is FIFO — second build waits for first.
This is the same as `cancel-in-progress: false` in GitHub Actions.

Without the lock, two pushes 30 seconds apart would both run `helm upgrade`
simultaneously. The second could overwrite the first's image tag mid-deploy,
leaving the cluster in an inconsistent state.

---

### Q4: How do you store and inject AWS credentials in Jenkins? What is the best practice?

**Answer:**
Best practice for Jenkins running on EC2: **attach an IAM Role to the EC2 instance**.
No credentials are stored anywhere.

The AWS SDK and CLI automatically query the EC2 Instance Metadata Service (IMDS)
at `http://169.254.169.254/...` to get temporary credentials. These rotate every
6 hours automatically.

In the Jenkinsfile there is no `withCredentials` for AWS at all:
```groovy
sh 'aws eks update-kubeconfig --name my-cluster --region us-east-1'
// Just works — IAM role handles auth
```

The IAM role is created by Terraform with least-privilege permissions:
only EKS describe, ECR push/pull, S3/DynamoDB for terraform state, ECS deploy.

What NOT to do:
- `AWS_ACCESS_KEY_ID` hardcoded in Jenkinsfile → key leaks in logs
- AWS credentials in Jenkins Credentials store with no rotation → stale keys
- `AdministratorAccess` policy → blast radius too large

For GitHub Actions, the equivalent is OIDC — GitHub's identity provider vouches
for the workflow and AWS issues a short-lived token without any stored secrets.

---

### Q5: What is the `input` step and when do you use it?

**Answer:**
The `input` step pauses the pipeline and waits for a human to approve before continuing.

```groovy
input message: 'Deploy to production?', ok: 'Deploy', submitter: 'admin'
```

The build shows a button in the Jenkins UI. If no one clicks within the timeout,
the build is aborted.

Use cases:
- Before applying Terraform to staging/prod — someone reviews the plan first
- Before deploying to production — change management approval
- After a smoke test fails — option to roll back manually

In our pipeline, the Terraform Apply stage uses `input` for any non-dev environment:
```groovy
if (params.TF_ENV != 'eks-dev') {
    input message: "Apply Terraform to ${params.TF_ENV}?", ok: 'Apply'
}
```

GitHub Actions equivalent: **Environment Protection Rules** (required reviewers).
The concept is identical — human gate before a sensitive operation.

---

### Q6: How do you implement change detection in Jenkins (there is no dorny/paths-filter)?

**Answer:**
With `git diff` in a `script {}` block:

```groovy
def base = sh(script: 'git rev-parse HEAD~1', returnStdout: true).trim()
def count = sh(
    script: "git diff --name-only ${base} HEAD -- src/catalog/ | wc -l",
    returnStdout: true
).trim().toInteger()
env.BUILD_CATALOG = count > 0 ? 'true' : 'false'
```

Then in the build stage:
```groovy
stage('catalog') {
    when { environment name: 'BUILD_CATALOG', value: 'true' }
    steps { ... }
}
```

Edge case to handle: on the very first commit, `HEAD~1` doesn't exist.
The fallback `2>/dev/null || git rev-parse HEAD` compares HEAD to itself → 0 changes.
This is intentional — first deploy is done manually (`Build with Parameters` to force all).

---

### Q7: What is a Multibranch Pipeline and why use it?

**Answer:**
A Multibranch Pipeline is a Jenkins job type that automatically discovers branches
(and PRs) in a repository that contain a `Jenkinsfile`, and creates a pipeline job
for each one.

```
GitHub repo has:
  main      branch with Jenkinsfile → Jenkins creates "retail-store/main"
  feat/eks  branch with Jenkinsfile → Jenkins creates "retail-store/feat/eks"
  PR #12                            → Jenkins creates "retail-store/PR-12"
```

Benefits:
- Each branch has independent build history
- PRs get automatic builds (CI check before merge)
- `when { branch 'main' }` conditions work correctly — deploy only runs on main
- New branches are auto-discovered, deleted branches auto-cleanup

Without Multibranch Pipeline you'd need to manually create a new job for every branch,
which defeats the purpose of a feature branch workflow.

---

### Q8: How do you make a Jenkins pipeline retry on failure?

**Answer:**
Use the built-in `retry()` step:

```groovy
retry(3) {
    sh '''
        aws ecs update-service ...
        aws ecs wait services-stable ...
    '''
}
```

The entire block retries up to 3 times if any step fails.
You can also combine with `sleep` to add backoff:

```groovy
retry(3) {
    try {
        sh 'aws ecs wait services-stable ...'
    } catch(e) {
        sleep(30)
        throw e
    }
}
```

GitHub Actions equivalent: `nick-fields/retry` action with `max_attempts: 3` and
`retry_wait_seconds: 30`.

Use retry for: transient AWS API errors, flaky network calls, ECS service stabilisation.
Do NOT use retry for: build failures, test failures, auth errors — these won't succeed
on retry and you're just wasting time.

---

### Q9: What is the difference between Jenkins and a GitOps tool like ArgoCD?

**Answer:**
They solve different problems and are often used together.

**Jenkins (push-based CI/CD):**
- Triggered by a git push event
- Actively pushes changes to the target environment
- Handles build, scan, test, AND deploy in one pipeline
- Good for: building images, running tests, complex deploy logic

**ArgoCD (pull-based GitOps):**
- Continuously watches a Git repo for changes
- Pulls desired state from Git and reconciles the cluster
- Detects and corrects drift automatically (someone manually changes K8s → ArgoCD reverts)
- Good for: declarative deployments, drift correction, multi-cluster sync

**How they work together (modern pattern):**
```
Developer pushes code
    │
    ▼
Jenkins Pipeline
    ├── Build Docker image
    ├── Run Trivy scan
    ├── Push image :{SHA}
    └── Update Helm values repo (imageTag: {SHA})
                │
                ▼ (ArgoCD watches values repo)
           ArgoCD detects change → syncs cluster
```

Jenkins handles CI (build/scan/push).
ArgoCD handles CD (deploy/reconcile).
Clean separation — you can replace either independently.

In this project we use Jenkins for the full cycle (including Helm deploy) —
ArgoCD is the recommended next step to split concerns.

---

### Q10: Jenkins is provisioned by Terraform — walk me through what happens from `terraform apply` to first pipeline run.

**Answer:**

1. **`terraform apply`** creates:
   - EC2 t3.medium (Ubuntu 22.04) in a public subnet
   - IAM role with EKS/ECR/S3 permissions — attached as instance profile
   - Security group — port 8080 and 22 open to your IP only
   - Elastic IP — stable public address

2. **First boot (~2-3 min):** `user_data.sh` runs automatically:
   - Installs Jenkins LTS + Java 21, Docker
   - Adds `jenkins` OS user to `docker` group (so pipelines can build images)
   - Installs AWS CLI, kubectl 1.32, Helm 3, Trivy, Terraform
   - Runs `aws eks update-kubeconfig` → writes kubeconfig to `/var/lib/jenkins/.kube/config`
   - Starts Jenkins service

3. **Initial setup (manual, one-time):**
   - Open `http://<EIP>:8080` in browser
   - Paste initial admin password from `/var/lib/jenkins/secrets/initialAdminPassword`
   - Install plugins: Lockable Resources, Docker Pipeline, GitHub Branch Source, AnsiColor
   - Add Docker Hub credential (ID: `docker-hub`)
   - Create Multibranch Pipeline → point to GitHub repo

4. **GitHub webhook:**
   - Add webhook in GitHub repo settings → `http://<EIP>:8080/github-webhook/`
   - Every push now triggers Jenkins immediately

5. **Pipeline run (push to `feat/eks`):**
   - Jenkins checks out code
   - Detects changed services via `git diff`
   - Builds + Trivy scans changed services in parallel
   - On `feat/eks` or `main`: acquires `eks-deploy` lock → helm upgrade → smoke test

Full infrastructure-as-code: destroy and recreate Jenkins with one `terraform apply`.
The only manual steps are the one-time Jenkins UI wizard (plugin install + credential).

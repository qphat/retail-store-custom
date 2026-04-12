# Interview Strategy — Tran Quang Phat
## Fresher+ / Junior DevOps — Next Week

> Written specifically for your background: 3 AWS certs, TCOM day job (CodePipeline/Beanstalk/EC2),
> and the retail-store-sample-app personal project (ECS Fargate + Terraform + GitHub Actions).

---

## The Core Tension You Must Manage

You have two realities:

| Reality | What it is |
|---|---|
| **Day job (TCOM)** | EC2, Elastic Beanstalk, CodePipeline/CodeBuild, Bitbucket Pipelines — no ECS, no Terraform modules, no K8s |
| **Personal project** | Docker, Docker Compose, K8s + Helm on Kind, ECS Fargate, Terraform multi-env, GitHub Actions, FireLens, Cloud Map, Kibana |

**The risk:** Interviewer asks "have you done X in production?" and you say yes, then can't explain details.

**The strategy:** Be upfront that the project is personal/self-built, but frame it as initiative and depth — not a gap.

> "At TCOM I work mainly with Beanstalk and CodePipeline. I built the ECS Fargate project
> personally to go deeper on container orchestration and IaC — I ran the full stack locally
> with Docker Compose, then on Kubernetes using Kind, then deployed to real AWS ECS Fargate."

That progression (Compose → Kind → ECS) is exactly how a mature engineer learns. Own it.

### Your container journey is a strength — it shows progression

```
Local dev    → Docker Compose   (all 5 services + Prometheus + Grafana + Kibana)
Local K8s    → Kind cluster     (raw manifests + Helm chart)
Production   → AWS ECS Fargate  (Terraform + GitHub Actions CI/CD)
```

Most candidates stop at Docker Compose. You went all three levels.

---

## How to Read Your Own CV Honestly

### Strong points (they will ask about these)
- **3 AWS certs** (SAA + Developer + Cloud Practitioner) — rare for fresh/junior, lead with these
- **TCOM: cross-VPC architecture** — real production networking experience
- **TCOM: CI/CD pipelines** (staging + prod via CodePipeline/CodeBuild) — real CI/CD experience
- **TCOM: nginx reverse proxy + SSL (Certbot)** — real ops experience
- **Personal project: Terraform modules** — shows IaC depth beyond day job

### Risky points (prepare carefully)
| CV claim | Risk | Preparation |
|---|---|---|
| "Microservices on EKS" | CV says EKS + .NET Core but actual project is ECS + Go/Java/Node on Kind | Fix CV — you ran K8s on Kind, not EKS |
| "DynamoDB locking for team-safe infra" | They may ask about lock conflicts | `use_lockfile = true` in S3 backend — you implemented this |
| "Integrated data endpoints Not AWS to S3, reducing overhead by 45%" | Vague — they will ask how you measured 45% | Prepare a specific answer or soften the claim |
| "EKS, Kubernetes, Docker, .NET Core" in skills | You ran K8s on Kind, not EKS | "I ran Kubernetes locally on Kind with Helm; my next step is EKS" — honest and still strong |

### Update your CV before the interview
Add the retail-store-sample-app project accurately:
```
Retail Store Microservices — Personal Project (2025-2026)
- Built 5-service polyglot app (Go, Java, Node) with Docker multi-stage builds and
  Docker Compose full-stack local dev (app + Prometheus + Grafana + Elasticsearch + Kibana)
- Deployed to Kubernetes on Kind using raw manifests and a single Helm chart covering
  all 5 services with ingress routing
- Deployed to AWS ECS Fargate using Terraform modules (VPC, ALB, ECS, Cloud Map, logging)
- Built GitHub Actions CI/CD: Trivy scan, SHA-pinned ECS task definitions,
  post-deploy smoke test across all services via ALB
- Implemented FireLens (Fluent Bit) → Elasticsearch logging; resolved ES 8.x breaking change
- Multi-environment Terraform (dev/staging/prod) with daily drift detection workflow
Tech: Docker, Docker Compose, Kubernetes, Helm, Kind, Terraform, ECS Fargate,
      GitHub Actions, Fluent Bit, Elasticsearch, Kibana, Prometheus, Grafana
```

---

## Your Opening Statement (memorize this)

When they say "tell me about yourself" or "walk me through your background":

> "I'm currently a Junior DevOps at TCOM, where I work on AWS infrastructure —
> cross-VPC networking, CI/CD with CodePipeline and Bitbucket, and Beanstalk deployments.
> I hold three AWS certifications — Solutions Architect, Developer, and Cloud Practitioner.
>
> Outside work, I built a personal project end-to-end: a 5-service polyglot microservices app.
> I started with Docker Compose locally — all 5 services plus the full observability stack.
> Then deployed to Kubernetes on Kind with a Helm chart. Then took it to real AWS: ECS Fargate
> with Terraform, GitHub Actions CI/CD with Trivy scanning and SHA-pinned deploys, and
> Fluent Bit log routing to Elasticsearch. I hit several real issues along the way —
> Elasticsearch 8.x breaking changes, Fargate CPU/memory constraints, Cloud Map service
> discovery gaps — which taught me more than any tutorial would."

**Baits planted:**
- Cross-VPC → networking questions
- CodePipeline vs GitHub Actions → CI/CD comparison
- 3 certs → validates knowledge
- Docker Compose → Docker fundamentals
- Kubernetes + Helm on Kind → K8s questions
- ECS Fargate → compare K8s vs ECS
- Fluent Bit / ES issue → real debugging story
- Drift detection → Terraform maturity
- "Real issues" → they WILL ask "what issues?"

---

## Question-by-Question Preparation

---

### "Tell me about your CI/CD experience"

**At work (TCOM):**
> "At TCOM I set up CodePipeline + CodeBuild pipelines for staging and prod environments,
> and Bitbucket Pipelines for a client project — automated builds, deployments to Beanstalk,
> nginx + SSL config for the staging environment."

**Personal project (bridge):**
> "In my personal project I went deeper with GitHub Actions — matrix builds across 5 services,
> change detection so only modified services rebuild, Trivy image scanning before push,
> and proper ECS deployment: downloading the current task definition, rendering a new revision
> with the exact git SHA image tag, waiting for service stability, then HTTP health checks
> through the ALB. The key insight was that `:latest` tags are dangerous in CI — if two pushes
> happen simultaneously, the wrong image can end up deployed."

**Bait:** "SHA-pinned task definitions" → they ask why → talk about audit trail and rollback.

---

### "What's the difference between CodePipeline and GitHub Actions?"

| | CodePipeline | GitHub Actions |
|---|---|---|
| Trigger | AWS events, CodeCommit, GitHub | Git events, cron, webhook |
| Config | Console / CloudFormation | YAML in `.github/workflows/` |
| Native AWS | Deep (ECR, ECS, Beanstalk, Lambda) | Via `aws-actions/*` |
| Matrix builds | No native matrix | Yes — per-service, per-env |
| Cost | Per pipeline per month | Free for public, minutes for private |
| Learning curve | Lower for AWS-only teams | More portable, more community |

> "CodePipeline integrates very naturally with other AWS services — CodeBuild, ECR, Beanstalk —
> which is why we use it at TCOM. GitHub Actions is more flexible for complex matrix builds
> and has a huge community of reusable actions. For the ECS project I chose GitHub Actions
> because the matrix detection logic — only build the services that changed — is easier to
> express in YAML."

---

### "What is Terraform and why use it over CloudFormation?"

> "Terraform is an IaC tool that manages infrastructure as code using HCL. The main advantages
> over CloudFormation for me are: it's cloud-agnostic so skills transfer, the plan/apply
> workflow gives you an explicit preview before any changes, and the module system makes it easy
> to create reusable components — I wrote modules for VPC, ECS cluster, ALB, and per-service
> ECS tasks that I can instantiate for dev, staging, and prod with different parameters.
>
> CloudFormation has tighter AWS integration — stack rollbacks, native change sets — but
> Terraform's ecosystem is wider and the syntax is easier to read for complex infrastructure."

**Your real experience:** You wrote actual modules, hit real issues (backend config, `use_lockfile`, S3 bucket naming). You can talk about these.

---

### "Have you worked with containers/Docker?"

> "Yes — at TCOM we use Docker for builds in CodeBuild. In my personal project I went deeper:
> multi-stage Dockerfiles for 5 services across Go, Java, and Node. Locally I run the full
> stack with Docker Compose — all 5 services plus Prometheus, Grafana, Elasticsearch, and
> Kibana in a single `docker compose up`. Each service has its own compose file and the UI
> orchestrates the full stack.
>
> For security, I added Trivy scanning in the CI pipeline — it fails the build on CRITICAL
> CVEs before any image is pushed. In ECS, each task has a Fluent Bit sidecar container
> that routes logs to Elasticsearch using the FireLens driver."

**Bait:** "full observability stack in Compose" → they ask about Prometheus/Grafana → you know it.

---

### "What is ECS? How does it compare to EKS/Kubernetes?"

> "ECS is AWS's native container orchestration service. You define tasks (container specs) and
> services (desired count, load balancer, auto-scaling). With Fargate you don't manage any EC2
> nodes — AWS handles the underlying compute.
>
> I've run the same application both ways: Kubernetes on Kind locally, and ECS Fargate on AWS.
> The experience is quite different. In Kubernetes, I write Deployments, Services, and an
> Ingress manifest — then helm install to deploy. In ECS, I write Terraform for task definitions
> and services — AWS handles the scheduler.
>
> ECS is simpler for AWS-native teams — ALB, Cloud Map, IAM all integrate naturally.
> Kubernetes is more portable, has a richer ecosystem (Helm, ArgoCD, service meshes), and
> is the industry standard for larger organisations. For this project, I chose ECS for the
> AWS experience, but the Helm chart means I can switch to EKS without rewriting the app."

**If they push on production K8s experience:**
> "My K8s is on Kind locally — not production EKS. But I've gone beyond tutorials: I wrote
> the full Helm chart, configured ingress routing, and understand the differences between
> Deployment and StatefulSet. EKS is my next step."

Honest, specific, and shows genuine depth.

---

### "What is Helm and why use it?"

> "Helm is the package manager for Kubernetes — it lets you define your entire application
> as a chart: templates for Deployments, Services, Ingress, with values you override per
> environment. Without Helm, I'd have 5 separate Deployment YAML files and 5 Service YAMLs
> for my 5 services. With Helm, I have one chart that loops over a services map in values.yaml.
>
> The real power is environment promotion: `helm install --set imageTag=abc123` pins the
> exact version. `helm upgrade` does a rolling update. `helm rollback` reverts to the previous
> release. It's the same audit trail concept as SHA-pinned ECS task definitions, but
> native to Kubernetes."

**What you built:**
- `helm/retail-store/Chart.yaml` — chart metadata
- `helm/retail-store/values.yaml` — image registry, tag, per-service env vars
- `templates/deployment.yaml` — loops `range .Values.services` for all 5 services
- `templates/service.yaml` — same loop
- `templates/ingress.yaml` — conditional on `ingress.enabled`

---

### "What is the difference between Docker, Docker Compose, and Kubernetes?"

> "Docker builds and runs a single container. Docker Compose orchestrates multiple containers
> on a single machine — I use it locally to spin up all 5 services plus Prometheus, Grafana,
> Elasticsearch, and Kibana with one command. It's perfect for local dev but it's all on one
> host — no distribution, no auto-healing.
>
> Kubernetes orchestrates containers across a cluster of nodes — it handles scheduling,
> health checks, rolling deployments, auto-scaling, and self-healing. If a pod crashes,
> K8s restarts it. If a node dies, pods move to another node. I used Kind to run a local
> Kubernetes cluster on my laptop — Kind creates a full K8s cluster inside Docker containers.
>
> In production: Docker builds the image, CI pushes it, Kubernetes or ECS runs it."

**The hierarchy:**
```
Docker          — build and run one container
Docker Compose  — run multiple containers, one machine, local dev
Kubernetes      — run containers across a cluster, production
Kind            — run Kubernetes locally (K8s inside Docker, for learning/testing)
ECS Fargate     — run containers on AWS without managing nodes (AWS-managed K8s alternative)
```

---

### "Tell me about a problem you solved"

**Story 1: Fluent Bit / Elasticsearch 8.x (best story)**
> "After deploying the logging stack, all services were running but no logs appeared in Kibana.
> I checked CloudWatch and found Fluent Bit was returning HTTP 400 from Elasticsearch with
> 'unknown parameter [_type]'. After reading the ES 8.x migration guide, I found they removed
> the document type field — `_type` — which Fluent Bit was still sending by default.
> Removing that parameter from the FireLens log options fixed it immediately.
> What I learned: always check the version compatibility of your components, not just your
> own code."

**Story 2: Cloud Map / inter-service 500 errors (multi-layer debugging)**
> "After all services showed as running, the UI was returning 500 errors. I traced it through
> three separate issues that all had to be fixed together:
> First — the ECS module never registered services with Cloud Map, so DNS didn't exist.
> Second — even after adding Cloud Map, the URLs in env vars were missing the :8080 port,
> because Cloud Map A records give you an IP, not a host:port.
> Third — the security group only allowed traffic from the ALB, not from other services
> within the VPC CIDR.
> It was a good lesson that networking failures often have multiple root causes that must
> all be resolved — fixing one at a time wouldn't have helped."

**Story 3: Fargate CPU/memory constraints**
> "I set Kibana to 512 CPU / 1536 MB memory and Terraform apply failed with 'no Fargate
> configuration exists for that combination.' Fargate has fixed CPU/memory pairs — 512 CPU
> can only pair with 1024, 2048, 3072, or 4096 MB. Changed to 1024 MB, problem solved.
> Small thing but it cost 30 minutes because the error message wasn't obvious."

---

### "How do you automate Terraform in CI/CD?"

> "I have a dedicated `terraform.yml` GitHub Actions workflow separate from the app CI.
> It triggers on two events: pull requests touching `terraform/**`, and pushes to main.
>
> On a PR, it runs three things in parallel: lint (`terraform fmt -check` + `terraform validate`),
> security scanning with tfsec and checkov, and a `terraform plan` per changed environment.
> The plan output is posted as a comment on the PR — collapsible block so reviewers can see
> exactly what will change before approving.
>
> On merge to main, `apply-dev` runs automatically — no approval needed for dev.
> For staging and prod, I use GitHub Environments with required reviewers: you trigger
> `workflow_dispatch`, select the environment, and the workflow pauses for a human to approve
> before running `terraform apply`.
>
> Concurrency is important here — I set `cancel-in-progress: false` so if two Terraform
> runs target the same environment, the second one queues instead of cancelling. A cancelled
> mid-apply would leave infrastructure in a partial state."

**The 3 workflows you have:**

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform.yml` | PR + push to main | lint → plan → PR comment → apply (dev auto, staging/prod approval) |
| `ci.yml` | Push to main | build → scan → push image → deploy ECS → smoke test |
| `terraform-drift.yml` | Daily cron 6am UTC | plan per env → open GitHub Issue on drift |

---

### "What is infrastructure drift? How do you detect it?"

> "Drift is when the real AWS infrastructure no longer matches what Terraform describes —
> usually because someone made a manual change in the console or via CLI without updating
> the code. It's dangerous because the next `terraform apply` can revert or conflict with
> that change.
>
> I detect it with a separate scheduled GitHub Actions workflow — `terraform-drift.yml` —
> that runs every weekday morning at 6am UTC (1pm Vietnam time).
> It runs `terraform plan -detailed-exitcode -lock=false` for each environment.
> `-lock=false` because drift detection is read-only — no need to acquire the state lock.
> Exit code 0 = no drift. Exit code 2 = changes detected.
> On drift, it automatically opens a GitHub Issue with the full plan output and labels
> `terraform-drift` + the environment name. If the issue already exists from a previous run,
> it adds a comment instead of creating a duplicate."

---

### "What is a Terraform plan and why post it on PRs?"

> "A `terraform plan` shows exactly what Terraform will create, modify, or destroy before
> you run `apply`. It's a dry run — no changes to real infrastructure.
>
> Posting it on PRs is a safety gate: the reviewer sees the diff at the infrastructure level,
> not just the code level. If someone adds a security group rule that opens port 22 to the
> world, the plan shows it clearly — `+ ingress 0.0.0.0/0 port 22` — before it ever reaches
> AWS. It's the same idea as a code review but for infrastructure changes."

---

### "What is the difference between `terraform plan` and `terraform apply`?"

> "`terraform plan` reads the current state (from S3 remote backend), calls AWS APIs to
> compare with real infrastructure, and outputs what would change — additions in green,
> deletions in red, modifications in yellow. Nothing changes in AWS.
>
> `terraform apply` executes those changes against real AWS. In my CI pipeline, apply always
> requires a fresh plan — you can't apply a stale plan from an hour ago because the state
> might have changed. For dev I use `-auto-approve` in CI. For staging and prod, a human
> reviews the plan output in the PR comment before approving the apply job."

---

### "How do you handle secrets in AWS?"

> "In the ECS project, all secrets go through SSM Parameter Store as SecureString — KMS
> encrypted at rest. The task definition's `secrets` field references the SSM parameter ARN,
> and the execution role has permission to read it. At task start, ECS pulls the secret and
> injects it as an env var — the value is never stored in the task definition JSON or in Git.
>
> For application-level access to DynamoDB or S3, I use IAM task roles — the container
> inherits the role's permissions via instance metadata, no credentials in the code at all."

**Do NOT say:** "I use environment variables" without explaining where those vars come from.

---

### "What AWS certifications do you have and what did you learn?"

> "I have Solutions Architect Associate, Developer Associate, and Cloud Practitioner.
>
> SAA gave me the foundation — VPC design, security groups vs NACLs, how services
> integrate (ALB → ECS → RDS). Developer Associate went deeper on serverless and SDK usage.
>
> But honestly, building the actual project taught me more than any exam. The cert teaches
> you what services exist. Running `terraform apply` against real AWS and debugging why
> Fluent Bit can't connect to Elasticsearch teaches you how they actually work."

This answer shows maturity — you respect the certs but aren't hiding behind them.

---

### "Why DevOps? Why not pure Dev or pure Cloud?"

> "I like the intersection — writing infrastructure code, automating deployments, thinking
> about reliability. At TCOM I started in a more operations role but found myself writing
> Terraform and building pipelines more than clicking in the console. The personal project
> was me going all-in on that direction — if I'm going to do DevOps I want to understand
> it end to end, not just hand off a ticket to someone else."

---

### "Where do you see yourself in 2-3 years?"

> "Mid-level DevOps, comfortable with Kubernetes in production — I'm planning to move
> this project to EKS with ArgoCD next. I want to add full observability — metrics
> with Prometheus and Grafana, not just logging. And eventually platform engineering —
> building internal tooling that makes other developers faster."

---

## Culture & Behavioural Questions

These feel hard because there's no "right answer" — but there is a formula.

### The Formula: Situation → Action → Result (SAR)

Never answer culture questions in the abstract. Always tell a **specific story**.

```
Bad:  "My weakness is I work too hard."          (cliché, tells them nothing)
Good: "My weakness is [specific thing]. Here's a real example. Here's what I did about it."
```

---

### "What is your greatest strength?"

Pick ONE strength and prove it with a story from your project. Do not list 3-4 strengths — it sounds rehearsed.

**Your answer (use this):**
> "My strongest trait is that I debug by going to the source — logs, error codes, docs —
> rather than guessing. A good example: when the UI was returning 500 errors after deployment,
> I didn't just restart the service. I read the CloudWatch logs, traced the exact request
> path, and found it was actually three separate problems: Cloud Map registration missing,
> port not specified in the URL, and a security group blocking inter-service traffic.
> If I'd just restarted, none of those would have been fixed.
> I think that patience with root cause analysis is something I've built deliberately."

**Why this works:**
- Specific story, not a vague claim
- Shows technical depth
- Shows patience and systematic thinking
- Directly relevant to DevOps work

---

### "What is your greatest weakness?"

**Rules:**
1. Never say "I work too hard" or "I'm a perfectionist" — interviewers hate these
2. Pick a REAL weakness — they can tell when you're faking
3. Show what you're actively doing about it
4. Choose a weakness that doesn't disqualify you for the role

**Your answer (use this):**
> "My weakness is communication under pressure. When I'm deep in debugging a problem,
> I tend to go quiet — I focus on solving it and forget to update the people around me.
> At TCOM I had a situation where I was troubleshooting a pipeline issue for two hours
> and my manager didn't know the status. He had to come find me.
>
> I've been working on this deliberately — now I set a timer: if I've been stuck for
> more than 30 minutes, I send a short update even if I don't have a solution yet.
> It's a small habit but it's made a real difference."

**Why this works:**
- Real and believable
- Shows self-awareness
- Shows you're actively fixing it
- Not a disqualifying weakness for a DevOps role

---

### "Tell me about a time you failed"

> "I failed a DevSecOps interview earlier this year. I knew the tools — Docker, Trivy,
> tfsec — but I couldn't connect them into a coherent security philosophy. I answered
> questions about individual tools but couldn't explain the 'shift-left' mindset — why
> you scan at build time instead of after deployment, or why IaC security scanning
> matters before code even reaches AWS.
>
> After that I went and actually built it: Trivy in my CI pipeline that blocks on CRITICAL
> CVEs before any image is pushed, tfsec and checkov on every Terraform PR, SSM for secrets
> so nothing sensitive touches the codebase. Now I can explain not just what each tool does
> but why it sits where it does in the pipeline."

**This turns your VSI failure into your best culture answer.** Interviewers respect candidates who learn from failure and can articulate what changed.

---

### "Why do you want this role / this company?"

Never say "I want to learn" — it sounds like you're taking, not giving.

**Formula:** What they do → what you bring → what excites you about the intersection.

> "I've spent the past year building infrastructure from scratch — Terraform, ECS, CI/CD pipelines.
> I want to be somewhere I can apply that in a real team context, where there are harder
> problems than I can create for myself alone. From what I've read about [company], [specific
> thing they do] is exactly the kind of scale/challenge I want to work on next."

Fill in the `[company]` part specifically — generic answers fail here.

---

### "How do you handle conflict with a teammate?"

> "I try to separate the technical disagreement from the personal relationship. At TCOM
> there was a disagreement about whether to use Elastic Beanstalk or a custom EC2 setup
> for a deployment. I had a preference but so did the senior engineer. Instead of arguing,
> I wrote up a short comparison — pros/cons, time to implement, maintenance overhead —
> and we made the decision together from that. I was wrong about one of my assumptions
> and the comparison made that visible. I think having the data in writing keeps it
> professional."

---

### "How do you keep up with the industry?"

> "A mix of depth and breadth. For breadth I follow AWS release notes and the CNCF landscape —
> I want to know what exists even if I haven't used it. For depth I build things: the ECS
> Fargate project came from wanting to understand container orchestration properly, not just
> read about it.
>
> The VSI DevSecOps interview actually pushed me to go deeper on security — I went and added
> Trivy, tfsec, and checkov to my pipeline after that. Failing an interview is a good
> curriculum."

---

## DevSecOps — What VSI Was Looking For

You had the tools but not the framework. Here's the mental model:

### "Shift-Left" Security

```
Old way:   Build → Deploy → Security team scans → finds issues → fix → redeploy
                                                                  (expensive, slow)

Shift-left: Security checks happen AS EARLY AS POSSIBLE in the pipeline
            → catch issues when they're cheap to fix, not after deployment
```

**In your pipeline, shift-left looks like this:**

```
Code commit
    │
    ├── tfsec / checkov (IaC scan)     ← catches security misconfigs in Terraform
    │     "security group opens 0.0.0.0/0 on port 22"
    │
    ├── Trivy image scan               ← catches CVEs in container images
    │     "libssl has CRITICAL CVE — fail build"
    │
    ├── Secrets detection              ← catches hardcoded credentials
    │     (you use SSM — nothing to detect)
    │
    └── Deploy (only if all above pass)
```

### DevSecOps Q&A

**"What is DevSecOps?"**
> "DevSecOps integrates security into every stage of the DevOps pipeline instead of treating
> it as a separate phase at the end. The core idea is shift-left: find and fix security issues
> as early as possible, when they're cheap to fix. In my pipeline: tfsec and checkov scan
> Terraform on every PR before anything reaches AWS, Trivy scans the Docker image before it's
> pushed, and SSM means no secrets ever touch the codebase. Each check happens at the earliest
> possible point."

**"What is SAST vs DAST?"**
> "SAST — Static Application Security Testing — analyzes source code or built artifacts without
> running them. Trivy scanning a Docker image is SAST. tfsec scanning Terraform HCL is SAST.
> It runs in CI before deployment.
>
> DAST — Dynamic Application Security Testing — tests the running application by sending
> real requests. Tools like OWASP ZAP crawl your app and look for SQL injection, XSS, auth
> bypasses. It runs against a deployed environment, usually staging.
>
> In my current setup I have SAST (Trivy + tfsec). DAST against staging would be my next
> security addition."

**"How do you prevent secrets from leaking into code?"**
> "Three layers: SSM Parameter Store for all runtime secrets — nothing sensitive in the
> task definition or environment files. The IAM task role for AWS service access — no
> access keys in code at all. And OIDC for GitHub Actions — no long-lived AWS credentials
> stored in GitHub secrets. If I were adding a fourth layer, I'd add a secrets detection
> pre-commit hook or GitHub's secret scanning to catch anything that slips through."

**"What is the principle of least privilege?"**
> "Each identity should have only the permissions it needs for its specific job — nothing
> more. In my Terraform: the ECS execution role can only read SSM parameters under
> `/dev/*` — not all of SSM. The task role for cart can only access the specific DynamoDB
> table for that service — not all of DynamoDB. The GitHub Actions OIDC role can assume
> only the specific IAM role for this repo. Every permission is scoped as tightly as possible."

**"What security tools have you used?"**
> "Trivy for container image scanning — integrated in CI, blocks on CRITICAL CVEs with a
> fix available. tfsec and checkov for Terraform static analysis — catches misconfigs like
> security groups open to the world or unencrypted storage before they reach AWS. SSM
> SecureString for secrets — KMS encrypted at rest, never in plaintext. And OIDC for
> GitHub Actions authentication — removes the entire class of long-lived credential leaks."

---

## The "I Don't Know" Recovery

When they ask something you genuinely don't know:

**Never:** "I don't know." (full stop)

**Always:**
> "I haven't used X directly, but the closest thing I've worked with is [Y].
> For example, [specific story from your project or TCOM]..."

**Examples:**
- "I haven't used Jenkins but I've used both CodePipeline and GitHub Actions — happy to compare how I'd approach CI/CD in Jenkins."
- "I haven't used Ansible but I've used Terraform for infra provisioning — the difference I understand is Terraform for infra state, Ansible for config management on running machines."
- "I haven't used EKS in production yet, but I have the Helm chart and K8s manifests for this project — my next step is deploying to EKS."

---

## Danger Zones — What NOT to Say

| Situation | Don't say | Say instead |
|---|---|---|
| About TCOM work | "I set up Kubernetes at work" | "At work we use Beanstalk; I built K8s on Kind in my personal project" |
| About K8s experience | "I deployed to EKS" | "I ran K8s on Kind locally with Helm — not EKS yet, that's my next step" |
| About the 45% overhead claim | Make up numbers | "I measured it by comparing S3 transfer costs before/after" (only if true) |
| About Kind | "I used Kind in production" | "Kind is a local Kubernetes cluster — I used it to learn K8s before going to ECS" |
| About any tech | "I know X" and then can't explain it | Only claim what you can explain for 5 minutes |

---

## The Day Before the Interview

**Review these 7 things:**

1. Re-read your TCOM work stories — what exactly did you build, what problem did it solve
2. Re-read your 3 debugging stories (Fluent Bit, Cloud Map, Fargate constraints)
3. Know the full progression cold: Compose → Kind → ECS Fargate
4. Know your Helm chart structure: Chart.yaml, values.yaml, templates/ looping over services
5. Update your CV with the accurate project description
6. Know your numbers: 5 services, 3 environments, 3 certs, Go/Java/Node, Kind cluster
7. Draw the architecture from memory — both K8s version and ECS version

**Practice saying out loud:**
- Your opening statement (2 minutes)
- Each debugging story (2 minutes each)
- "At work I use X; in my personal project I went from Compose to Kind to ECS"
- The Docker vs Compose vs K8s distinction (interviewers love this)

---

## One-Page Architecture Cheat Sheet (memorize)

### Local (Docker Compose)
```
docker compose up (src/ui/)
    ├── ui         :8888
    ├── catalog    :8081
    ├── cart       :8082
    ├── orders     :8083
    ├── checkout   :8084
    ├── Prometheus :9090
    ├── Grafana    :3000
    ├── Elasticsearch
    └── Kibana     :5601
```

### Local Kubernetes (Kind)
```
kind create cluster --name retail --config kind-config.yaml
    │
    ├── kubectl apply -f k8s/          (raw manifests)
    │     └── Deployment + Service per service + Ingress
    │
    └── helm install retail-store helm/retail-store/
          ├── Chart.yaml
          ├── values.yaml             (image, tag, env vars per service)
          └── templates/
                ├── deployment.yaml   (range .Values.services)
                ├── service.yaml      (range .Values.services)
                └── ingress.yaml      (conditional)
```

### Production (AWS ECS Fargate via Terraform + GitHub Actions)
```
GitHub (code)
    │
    ▼
GitHub Actions CI
    ├── detect-changes (paths-filter)
    ├── build (Docker multi-stage)
    ├── scan (Trivy CRITICAL CVEs)
    ├── push (Docker Hub :{sha} + :latest)
    └── deploy
          ├── download current task def
          ├── render new image (SHA-pinned)
          ├── register new revision
          ├── update service + wait stable
          └── HTTP health check via ALB + smoke test

AWS Infrastructure (Terraform)
    ├── VPC (public + private subnets, NAT gateway)
    ├── ALB (HTTP listener, path-based routing)
    ├── ECS Cluster (Fargate)
    ├── 5x ECS Services
    │     ├── app container
    │     └── log_router (Fluent Bit FireLens sidecar)
    ├── Cloud Map (DNS: {service}.dev.local → private IP)
    ├── Elasticsearch + Kibana (logging)
    └── SSM (secrets: no plaintext anywhere)

Environments: dev (auto-apply) → staging (approval) → prod (approval)
Drift detection: daily cron → GitHub Issue on changes
```

---

*Good luck. You built real infrastructure, hit real problems, solved them. That's the story.*

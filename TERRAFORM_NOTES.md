# Terraform Notes — ECS Fargate + EFK on LocalStack

Learning notes for the retail-store-sample-app Terraform infrastructure.
Covers concepts from scratch through multi-environment ECS Fargate with EFK logging.

---

## Table of Contents

1. [What is Terraform?](#1-what-is-terraform)
2. [Core Concepts](#2-core-concepts)
3. [HCL Syntax Crash Course](#3-hcl-syntax-crash-course)
4. [Terraform Workflow](#4-terraform-workflow)
5. [State Management](#5-state-management)
6. [Providers](#6-providers)
7. [Modules](#7-modules)
8. [Variables, Outputs, Locals](#8-variables-outputs-locals)
9. [Key Built-in Functions](#9-key-built-in-functions)
10. [Multi-Environment Pattern](#10-multi-environment-pattern)
11. [LocalStack Setup](#11-localstack-setup)
12. [AWS + ECS Fargate Concepts](#12-aws--ecs-fargate-concepts)
13. [EFK Logging on ECS (FireLens)](#13-efk-logging-on-ecs-firelens)
14. [This Project's Architecture](#14-this-projects-architecture)
15. [Common Issues & Fixes](#15-common-issues--fixes)
16. [Interview Q&A](#16-interview-qa)

---

## 1. What is Terraform?

**Terraform** is an Infrastructure as Code (IaC) tool by HashiCorp. You describe infrastructure in `.tf` files and Terraform figures out how to create/update/delete it.

### Why Terraform over manual AWS console?

| Manual Console | Terraform |
|---|---|
| Click buttons, easy to forget what you did | Code in Git — full history |
| Hard to reproduce in another environment | `cp environments/dev environments/staging` |
| No review process | PR review before `apply` |
| Drift: console changes not tracked | `terraform plan` shows drift |
| Hard to tear down cleanly | `terraform destroy` removes everything |

### Terraform vs other IaC tools

| Tool | Approach | Language |
|---|---|---|
| Terraform | Declarative, multi-cloud | HCL |
| CloudFormation | Declarative, AWS-only | YAML/JSON |
| Pulumi | Imperative, multi-cloud | Python/Go/TypeScript |
| Ansible | Procedural, config management | YAML |
| CDK | Imperative, generates CF/TF | TypeScript/Python |

**Declarative** = you say *what* you want, not *how* to get there.
Terraform computes the diff between current state and desired state, then acts.

---

## 2. Core Concepts

### Resource
The fundamental unit. Represents one real infrastructure object.

```hcl
resource "aws_ecs_cluster" "main" {   # type = "aws_ecs_cluster", name = "main"
  name = "dev-retail-store"
}
```

`aws_ecs_cluster.main` is the address you use to reference this resource elsewhere.

### Provider
Plugin that talks to a specific API (AWS, GCP, Azure, Kubernetes...).
Providers translate HCL into API calls.

```hcl
provider "aws" {
  region = "us-east-1"
}
```

### Data Source
Read-only — fetch existing info from the API, don't create anything.

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}
# Use: data.aws_availability_zones.available.names
```

### Module
A folder of `.tf` files packaged as a reusable unit.
Modules take inputs (variables), create resources, and expose outputs.

### State
Terraform tracks what it created in a **state file** (`terraform.tfstate`).
Without state, Terraform can't know what already exists vs what to create.

### Plan vs Apply
- `terraform plan` — preview changes (dry run, no modifications)
- `terraform apply` — make the changes real

---

## 3. HCL Syntax Crash Course

HCL = HashiCorp Configuration Language. JSON-compatible but more readable.

```hcl
# String
name = "dev-retail-store"

# Number
cpu = 512

# Boolean
essential = true

# List
subnet_ids = ["subnet-aaa", "subnet-bbb"]

# Map
tags = {
  Environment = "dev"
  Project     = "retail-store"
}

# Reference another resource's attribute
vpc_id = aws_vpc.main.id

# Reference a module output
cluster_id = module.ecs_cluster.cluster_id

# String interpolation
name = "${var.env_name}-retail-store"

# Conditional (ternary)
value = var.container_insights ? "enabled" : "disabled"

# For expression — transform a list
environment = [
  for k, v in var.environment_vars : { name = k, value = v }
]

# Heredoc string
command = <<-EOT
  echo "hello"
  curl http://example.com
EOT
```

### Block types

```hcl
resource "TYPE" "NAME" { ... }      # create infrastructure
data "TYPE" "NAME" { ... }          # read existing infrastructure
variable "NAME" { ... }             # input parameter
output "NAME" { ... }               # expose a value
locals { ... }                      # computed constants (no input/output)
module "NAME" { source = "..." }    # call a module
provider "NAME" { ... }             # configure provider
terraform { ... }                   # Terraform settings (version, backend)
```

---

## 4. Terraform Workflow

```
Write .tf files
      │
      ▼
terraform init        ← download providers + modules, set up backend
      │
      ▼
terraform validate    ← syntax check (optional but fast)
      │
      ▼
terraform plan        ← show what will change (+/-/~)
      │
      ▼
terraform apply       ← actually create/modify/delete
      │
      ▼
terraform destroy     ← tear everything down
```

### init in detail

```bash
terraform init
```

- Downloads the provider plugins (e.g. `hashicorp/aws ~> 5.0`) to `.terraform/`
- Initialises the backend (creates state storage if needed)
- Reads module sources
- **Must re-run** when you change providers, modules, or backend

### plan output explained

```
  # aws_vpc.main will be created
  + resource "aws_vpc" "main" {
      + cidr_block           = "10.0.0.0/16"
      + enable_dns_support   = true
      + id                   = (known after apply)    # AWS assigns this
    }

Plan: 12 to add, 0 to change, 0 to destroy.
```

`+` = create, `~` = update in-place, `-/+` = destroy and recreate, `-` = destroy

### apply flags

```bash
terraform apply                   # interactive — asks "yes/no"
terraform apply -auto-approve     # skip confirmation (CI/CD)
terraform apply -target=module.vpc  # apply only the VPC module
terraform apply -var="env_name=staging"  # override a variable
```

---

## 5. State Management

### What is state?

State (`terraform.tfstate`) is Terraform's memory. It maps:
- Your HCL resource names → real AWS resource IDs
- `aws_vpc.main` → `vpc-0abc123def456789`

Without state, Terraform would try to recreate everything on every apply.

### Local state (this project)

```hcl
# environments/dev/backend.tf
terraform {
  backend "local" {
    path = "dev.tfstate"
  }
}
```

- File stays on your machine
- Simple for solo learning / LocalStack
- **Problem:** can't share with a team, no locking (two applies at once = corruption)

### Remote state (production best practice)

```hcl
terraform {
  backend "s3" {
    bucket         = "my-tf-state-bucket"
    key            = "retail-store/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"  # prevents concurrent applies
  }
}
```

- State stored in S3 (durable, versioned)
- DynamoDB table = distributed lock (only one `apply` at a time)
- Team can share state

### State commands

```bash
terraform show                          # show current state in human-readable form
terraform state list                    # list all resources in state
terraform state show aws_vpc.main       # show one resource's state
terraform state rm aws_vpc.main         # remove from state (does NOT delete the resource)
terraform import aws_vpc.main vpc-0abc  # import existing resource into state
```

### State drift

When someone modifies infrastructure outside Terraform (e.g. clicking in the AWS console):

```bash
terraform plan   # shows drift as "~ will be updated" or "-/+ will be replaced"
terraform apply  # brings real infra back in line with your .tf files
terraform refresh  # update state to match real infra (without applying)
```

---

## 6. Providers

### How providers work

Providers are plugins. Each provider knows how to talk to one API.
Terraform downloads them into `.terraform/providers/` during `init`.

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"   # registry.terraform.io/hashicorp/aws
      version = "~> 5.0"          # any 5.x version
    }
  }
}
```

### Version constraints

| Constraint | Meaning |
|---|---|
| `= 5.0.0` | Exactly 5.0.0 |
| `>= 5.0` | 5.0 or higher |
| `~> 5.0` | >= 5.0, < 6.0 (patch/minor updates ok) |
| `~> 5.23.0` | >= 5.23.0, < 5.24 (patch only) |

### LocalStack provider config

LocalStack simulates AWS APIs locally. The provider redirects all calls to `localhost:4566`:

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "test"   # LocalStack accepts any non-empty value
  secret_key = "test"

  # Skip validation calls that would fail against LocalStack
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ecs              = "http://localhost:4566"
    ec2              = "http://localhost:4566"
    iam              = "http://localhost:4566"
    logs             = "http://localhost:4566"   # CloudWatch Logs
    ssm              = "http://localhost:4566"
    elbv2            = "http://localhost:4566"   # ALB
    servicediscovery = "http://localhost:4566"   # Cloud Map
  }
}
```

Why `skip_*`? LocalStack doesn't have real IAM accounts. Without these flags the provider calls `sts:GetCallerIdentity` to validate credentials — which would fail against LocalStack.

---

## 7. Modules

### What is a module?

Any directory with `.tf` files is a module. You call it with a `module` block:

```hcl
module "vpc" {
  source     = "../../modules/vpc"   # relative path
  env_name   = "dev"
  cidr_block = "10.0.0.0/16"
}
```

### Why use modules?

- **Reuse:** same VPC logic for dev/staging/prod — just different variables
- **Encapsulation:** callers don't see internal resources, only outputs
- **Testability:** you can test a module in isolation

### Module anatomy

```
modules/vpc/
├── variables.tf   ← inputs (what callers must/can provide)
├── main.tf        ← resources (the actual infrastructure)
└── outputs.tf     ← outputs (what callers can reference)
```

### Calling a module

```hcl
# Module call
module "vpc" {
  source     = "../../modules/vpc"
  env_name   = var.env_name       # pass caller's variable into module
  cidr_block = "10.0.0.0/16"
}

# Use module output
resource "aws_ecs_service" "this" {
  ...
  network_configuration {
    subnets = module.vpc.private_subnet_ids  # output from vpc module
  }
}
```

### Module sources

```hcl
source = "../../modules/vpc"                      # local path
source = "github.com/org/repo//modules/vpc"       # GitHub
source = "registry.terraform.io/hashicorp/consul" # Terraform Registry
source = "git::https://example.com/repo.git"      # Generic Git
```

This project uses **local modules** — best for learning because you can read and modify them.

### Root module vs child modules

- **Root module:** the directory where you run `terraform apply` (e.g. `environments/dev/`)
- **Child modules:** modules called from the root (e.g. `modules/vpc/`)

---

## 8. Variables, Outputs, Locals

### Variables (inputs)

```hcl
# Declaration
variable "env_name" {
  type        = string
  description = "Environment name (dev, staging, prod)"
  default     = "dev"    # optional — if omitted, required at apply time
}

# Types: string, number, bool, list(string), map(string), object({...}), any
variable "environment_vars" {
  type    = map(string)
  default = {}
}
```

**How to set variables:**

```bash
# 1. terraform.tfvars (auto-loaded)
env_name = "dev"

# 2. -var flag
terraform apply -var="env_name=staging"

# 3. TF_VAR_ environment variable
export TF_VAR_env_name=staging

# 4. Interactive prompt (if no default and no value provided)
```

### Outputs

```hcl
# Declaration (in a module or root)
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
  sensitive   = false   # set true for passwords, tokens
}

# Calling from root module
module "vpc" { ... }

module "ecs_cluster" {
  vpc_id = module.vpc.vpc_id   # consume the output
}
```

After `apply`, root outputs are printed:
```
Outputs:
alb_dns_name = "dev-retail-store-123456.us-east-1.elb.amazonaws.com"
```

### Locals

Computed values local to a module — not inputs, not outputs. Used to avoid repetition:

```hcl
locals {
  full_name     = "${var.env_name}-${var.service_name}"   # "dev-catalog"
  log_group_app = "/ecs/${var.env_name}/${var.service_name}"
}

resource "aws_ecs_service" "this" {
  name = local.full_name   # reuse without repeating the expression
}
```

---

## 9. Key Built-in Functions

### `jsonencode()`

Converts HCL value to a JSON string. Used for ECS container definitions:

```hcl
container_definitions = jsonencode([
  {
    name  = "catalog"
    image = "koomi1/retail-app-catalog:latest"
    portMappings = [{ containerPort = 8080 }]
  }
])
```

Why not a raw JSON heredoc? `jsonencode` validates structure at plan time and handles escaping automatically.

### `templatefile()`

Reads a file and substitutes variables. Used for the Fluent Bit config:

```hcl
resource "aws_ssm_parameter" "fluent_bit_config" {
  value = templatefile("${path.module}/fluent-bit.conf.tpl", {
    es_host  = "elasticsearch.dev.local"
    env_name = "dev"
    log_level = "warn"
  })
}
```

`${path.module}` = the directory containing the current `.tf` file.

### `cidrsubnet()`

Calculate a subnet CIDR from a parent CIDR:

```hcl
# cidrsubnet(prefix, newbits, netnum)
# parent: 10.0.0.0/16, newbits: 8 (adds 8 bits → /24), netnum: 0,1,2...
cidrsubnet("10.0.0.0/16", 8, 0)   # → "10.0.0.0/24"
cidrsubnet("10.0.0.0/16", 8, 1)   # → "10.0.1.0/24"
cidrsubnet("10.0.0.0/16", 8, 10)  # → "10.0.10.0/24"
```

### `slice()`

Get a subset of a list:

```hcl
slice(data.aws_availability_zones.available.names, 0, var.az_count)
# ["us-east-1a", "us-east-1b", "us-east-1c"][0:2] → ["us-east-1a", "us-east-1b"]
```

### `merge()`

Merge two maps (second map wins on key collision):

```hcl
tags = merge(var.tags, { Name = "${var.env_name}-vpc" })
# var.tags = { Environment = "dev", Project = "retail-store" }
# result  = { Environment = "dev", Project = "retail-store", Name = "dev-vpc" }
```

### `replace()`

```hcl
# Strip "http://" and ":9200" from the ES URL to get just the hostname
es_host = replace(replace(var.elasticsearch_url, "http://", ""), ":9200", "")
```

### `for` expression

```hcl
# Transform map → list of {name, value} objects (for ECS env vars)
environment = [
  for k, v in var.environment_vars : { name = k, value = v }
]

# Filter a list
private_ids = [for s in aws_subnet.all : s.id if !s.map_public_ip_on_launch]
```

### `count` vs `for_each`

```hcl
# count — creates N copies, referenced by index
resource "aws_subnet" "public" {
  count      = var.az_count
  cidr_block = cidrsubnet(var.cidr_block, 8, count.index)
}
# Reference: aws_subnet.public[0].id, aws_subnet.public[1].id

# for_each — creates one copy per map entry, referenced by key
resource "aws_ecs_service" "services" {
  for_each = { ui = 512, catalog = 256 }
  name     = each.key    # "ui" or "catalog"
  cpu      = each.value  # 512 or 256
}
# Reference: aws_ecs_service.services["ui"].id
```

**When to use which?**
- `count` for homogeneous lists where index is meaningful (subnets across AZs)
- `for_each` for maps/sets where you want stable keys (services, users) — safer for partial deletes

---

## 10. Multi-Environment Pattern

### This project's approach: one root module per environment

```
terraform/
├── modules/          ← shared blueprints
│   ├── vpc/
│   ├── ecs-cluster/
│   ├── alb/
│   ├── ecs-service/
│   └── logging/
└── environments/
    ├── dev/          ← independent Terraform root (own state, own tfvars)
    ├── staging/
    └── prod/
```

Each environment directory:
- Has its own `terraform.tfstate` (isolated blast radius)
- Calls the same modules with different variables
- Is deployed independently: `cd environments/prod && terraform apply`

### Alternative: workspaces

```bash
terraform workspace new staging
terraform workspace select staging
terraform apply -var-file=staging.tfvars
```

Workspaces share the same code but use separate state files.
**Not recommended** for real multi-env — environments often need different code too, not just different vars.

### Environment differences in this project

| Setting | dev | staging | prod |
|---|---|---|---|
| CIDR | 10.0.0.0/16 | 10.1.0.0/16 | 10.2.0.0/16 |
| ui_cpu | 512 | 512 | 1024 |
| ui_memory | 1024 | 1024 | 2048 |
| desired_count | 1 | 1 | 2 |
| es_memory | 2048 | 2048 | 4096 |
| ES heap | 512m | 512m | 2g |

Different CIDRs: prevents overlap if you ever peer VPCs for cross-env traffic.
`desired_count=2` in prod: ALB distributes traffic across 2 tasks — if one crashes, the other handles traffic while ECS replaces the failed task.

---

## 11. LocalStack Setup

LocalStack is a local AWS simulation. Free tier supports most services used here.

### Start LocalStack

```bash
# Docker (recommended)
docker run -d \
  -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN=your_token \  # pro tier (needed for some services)
  localstack/localstack

# Or via localstack CLI
localstack start -d

# Check health
curl http://localhost:4566/_localstack/health | jq .services
```

### Install AWS CLI for LocalStack

```bash
pip install awscli-local   # adds 'awslocal' alias
awslocal ecs list-clusters
# equivalent to: aws --endpoint-url=http://localhost:4566 ecs list-clusters
```

### Useful LocalStack verification commands

```bash
# After terraform apply, check resources were created:
awslocal ec2 describe-vpcs --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock}'
awslocal ecs list-clusters
awslocal ecs list-services --cluster dev-retail-store
awslocal elbv2 describe-load-balancers
awslocal ssm get-parameter --name /dev/fluent-bit/config
awslocal ecs describe-task-definition --task-definition dev-catalog \
  | jq '.taskDefinition.containerDefinitions[].name'

# List all LocalStack resources
awslocal resourcegroupstaggingapi get-resources
```

### LocalStack free vs pro

| Feature | Free | Pro |
|---|---|---|
| EC2, VPC, S3, IAM, SQS, SNS | ✓ | ✓ |
| ECS, ELB/ALB, CloudWatch | ✓ | ✓ |
| Cloud Map (servicediscovery) | ✓ | ✓ |
| RDS, EKS, MSK | ✗ | ✓ |
| Real networking (container-to-container) | ✗ | ✓ (via ECS Fargate emulation) |

Note: On free tier, Fargate tasks are registered in state but containers don't actually run. LocalStack Pro is needed for real container execution.

---

## 12. AWS + ECS Fargate Concepts

### ECS Components

```
ECS Cluster
  └── ECS Service  ←── desired_count=2 (maintain 2 running tasks)
        └── ECS Task  ←── one running instance of the task definition
              └── Container(s)  ←── Docker containers inside the task
```

**Task Definition** = recipe (what image, how much CPU/memory, what ports, env vars, log config)
**Task** = one running instance of that recipe
**Service** = keeps N tasks running, replaces unhealthy ones, integrates with ALB

### Fargate vs EC2 launch type

| | Fargate | EC2 |
|---|---|---|
| Nodes | AWS manages | You manage EC2 instances |
| Scaling | Instant (no node provisioning) | Must scale EC2 first |
| Pricing | Per task CPU/memory used | Per EC2 instance (running or not) |
| Privileged containers | ✗ | ✓ |
| Host volume mounts | ✗ | ✓ |
| vm.max_map_count sysctl | ✗ (no privileged) | ✓ |
| Cost at low utilisation | Higher | Lower |
| Operational overhead | Low | Higher |

**This project uses Fargate** — simpler for learning, no node management.

### Networking (awsvpc mode)

Every Fargate task gets its own **Elastic Network Interface (ENI)** with a private IP.
This is why `target_type = "ip"` is required for ALB target groups (not `instance`).

```
ALB (public subnet, port 80)
  │
  │  routes to Target Group
  ▼
Task ENI (private subnet, port 8080)
  │
  └── Container (port 8080)
```

### IAM: Execution Role vs Task Role

Two separate IAM roles per task — easy to confuse:

| | Execution Role | Task Role |
|---|---|---|
| Who uses it | ECS agent (the infrastructure) | Your app code |
| Purpose | Pull Docker image, push logs to CloudWatch, read SSM secrets | Call AWS services (S3, DynamoDB, SQS...) |
| Attached policy | `AmazonECSTaskExecutionRolePolicy` (AWS managed) | Custom policy per service |
| `execution_role_arn` | ✓ | ✗ |
| `task_role_arn` | ✗ | ✓ |

In this project, the task role is empty (all services use in-memory persistence). In real projects: cart task role gets DynamoDB access, orders gets RDS access, etc.

### ALB Listener Rules

ALB evaluates rules in priority order (lowest number first):

```
Priority 5:  path /kibana*  → kibana target group
Priority 10: path /catalogue* → catalog target group
Priority 100: path /*        → ui target group (catch-all)
```

If no rule matches → default action (our empty 404 target group).

### CloudWatch Log Groups

Every service gets its own log group:
```
/ecs/dev/catalog           ← catalog app container logs
/ecs/dev/catalog/firelens  ← Fluent Bit sidecar operational logs
/ecs/dev/elasticsearch     ← ES logs
/ecs/dev/kibana            ← Kibana logs
```

---

## 13. EFK Logging on ECS (FireLens)

### Why EFK not ELK?

In the Helm chart you used **Filebeat** (the F in ELK). Filebeat runs as a DaemonSet (one pod per K8s node) and reads container logs from `/var/log/containers/` on the host.

ECS Fargate has no host access — containers are isolated. No DaemonSet equivalent. Instead, ECS has **FireLens**.

### What is FireLens?

FireLens is an ECS log routing feature. It injects **Fluent Bit** (or Fluentd) as a sidecar container into your task. Your app container's stdout is intercepted by ECS and sent to the FireLens sidecar via a Unix socket.

```
App Container stdout
    │
    │  (via awsfirelens log driver)
    │  ECS intercepts stdout, sends to log_router via Unix socket
    ▼
log_router (Fluent Bit)
    │
    ├──▶ Elasticsearch (primary output)
    │
    └──▶ CloudWatch (Fluent Bit's own operational logs)
```

### K8s vs ECS logging comparison

| | Kubernetes (Helm chart) | ECS Fargate (Terraform) |
|---|---|---|
| Log collector | Filebeat DaemonSet | Fluent Bit FireLens sidecar |
| One collector per | Node (all pods share) | Task (one per running task) |
| Host log path | `/var/log/containers/*.log` | No host access needed |
| K8s metadata | `add_kubernetes_metadata` processor | No equivalent (ECS has task metadata endpoint) |
| Log driver | Default (json-file) | `awsfirelens` |
| RBAC needed | Yes (ClusterRole for pod metadata) | No (Fluent Bit doesn't query the API) |

### FireLens task definition (annotated)

```json
[
  {
    "name": "log_router",
    "image": "fluent/fluent-bit:3.0",
    "essential": false,
    // ← if Fluent Bit crashes, the app task keeps running
    // In K8s: Filebeat pod crash doesn't affect app pods (separate pod)
    // In ECS: sidecar crash WOULD kill the task if essential=true

    "firelensConfiguration": {
      "type": "fluentbit",
      "options": {
        "config-file-type": "file",
        "config-file-value": "/fluent-bit/etc/fluent-bit.conf"
        // ← custom config overrides AWS defaults
        // AWS default config only outputs to CloudWatch
        // We override to add Elasticsearch output
      }
    },

    "logConfiguration": {
      "logDriver": "awslogs",    // ← Fluent Bit's OWN logs go to CloudWatch
      // NOT awsfirelens (that would be circular: Fluent Bit routing its own logs through itself)
    }
  },

  {
    "name": "catalog",
    "image": "koomi1/retail-app-catalog:latest",
    "essential": true,

    "logConfiguration": {
      "logDriver": "awsfirelens",   // ← KEY: sends stdout to log_router
      "options": {
        "service": "catalog",        // these become Fluent Bit record fields
        "env": "dev"
      }
    },

    "dependsOn": [{
      "containerName": "log_router",
      "condition": "START"
      // START = Fluent Bit process has started (not necessarily healthy)
      // HEALTHY = would need a healthCheck defined on log_router
      // We use START to avoid extra complexity
    }]
  }
]
```

### Fluent Bit config (fluent-bit.conf.tpl)

```ini
[SERVICE]
    Flush     1          # send logs every 1 second
    Log_Level warn       # Fluent Bit's own log verbosity

[FILTER]
    Name   record_modifier
    Match  *             # apply to all log records
    Record environment dev
    Record cluster     retail-store

[OUTPUT]
    Name         es
    Match        *
    Host         elasticsearch.dev.local    # Cloud Map DNS
    Port         9200
    Index        logs-catalog               # per-service index
    tls          Off
    Retry_Limit  3                          # retry up to 3 times if ES is slow
    Generate_ID  On                         # add unique _id field
    Replace_Dots On                         # ES rejects field names with dots
    storage.total_limit_size 5M            # buffer if ES is temporarily down
```

### Elasticsearch on Fargate — constraints

**Problem:** ES 8.x requires `vm.max_map_count=262144`.
In K8s you used an initContainer with `sysctl -w vm.max_map_count=262144` and `privileged: true`.
Fargate doesn't support privileged containers.

**Solution:** Set `bootstrap.memory_lock=false`. ES warns at startup but runs.

```json
{ "name": "bootstrap.memory_lock", "value": "false" }
```

**Multi-node ES on Fargate:** Not possible. ES cluster discovery requires:
1. Each node knows other nodes' IPs at startup
2. Persistent storage (EBS) per node — Fargate uses ephemeral storage
3. Kernel sysctl settings

Solution: `discovery.type=single-node`. One ES task = self-elected master + data node.
HA for logging comes from **Fluent Bit's retry buffer** (logs survive if ES restarts briefly).

### Cloud Map (Service Discovery)

In K8s, services discover each other via ClusterIP DNS (`http://catalog`, `http://elasticsearch`).
In ECS, there's no built-in DNS — you need **AWS Cloud Map**.

```hcl
# Create a private DNS namespace: dev.local
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "dev.local"
  vpc  = aws_vpc.main.id
}

# Register Elasticsearch with Cloud Map
resource "aws_service_discovery_service" "elasticsearch" {
  name = "elasticsearch"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records { type = "A"; ttl = 10 }
  }
}

# Attach to ECS Service
resource "aws_ecs_service" "elasticsearch" {
  service_registries {
    registry_arn = aws_service_discovery_service.elasticsearch.arn
  }
}
```

Result: `elasticsearch.dev.local:9200` resolves to the task's private IP. When ECS replaces a task, Cloud Map automatically updates the DNS record.

K8s equivalent: ClusterIP Service + internal DNS (`elasticsearch.default.svc.cluster.local`).

### SSM Parameter Store for Fluent Bit config

Instead of baking the Fluent Bit config into the Docker image, store it in SSM:

```hcl
resource "aws_ssm_parameter" "fluent_bit_config" {
  name  = "/dev/fluent-bit/config"
  type  = "String"
  value = templatefile("${path.module}/fluent-bit.conf.tpl", {
    es_host  = "elasticsearch.dev.local"
    env_name = "dev"
    log_level = "warn"
  })
}
```

Task definition reads it as a secret (via execution role's SSM permission):
```json
{
  "secrets": [
    { "name": "FLUENT_BIT_CONFIG", "valueFrom": "/dev/fluent-bit/config" }
  ]
}
```

Benefits:
- Change Fluent Bit config without rebuilding/redeploying the image
- SSM path is per-environment (`/dev/fluent-bit/config`, `/prod/fluent-bit/config`)
- Encrypted at rest (SSM SecureString for sensitive data)

---

## 14. This Project's Architecture

### Full resource map

```
environments/dev/
  module.vpc
    aws_vpc.main                     (10.0.0.0/16)
    aws_subnet.public[0,1]           (10.0.0.0/24, 10.0.1.0/24)
    aws_subnet.private[0,1]          (10.0.10.0/24, 10.0.11.0/24)
    aws_internet_gateway.main
    aws_eip.nat + aws_nat_gateway.main
    aws_route_table.public/private
    aws_route_table_association x4

  module.ecs_cluster
    aws_ecs_cluster.main             (dev-retail-store)
    aws_cloudwatch_log_group.cluster (/ecs/dev/cluster)

  module.alb
    aws_security_group.alb           (port 80 from 0.0.0.0/0)
    aws_lb.main                      (dev-retail-store ALB)
    aws_lb_target_group.default      (default 404)
    aws_lb_listener.http             (port 80)

  module.logging
    aws_ssm_parameter.fluent_bit_config   (/dev/fluent-bit/config)
    aws_service_discovery_private_dns_namespace.main (dev.local)
    aws_service_discovery_service.elasticsearch
    aws_service_discovery_service.kibana
    aws_iam_role.logging_execution
    aws_security_group.elasticsearch (9200 from VPC CIDR)
    aws_security_group.kibana        (5601 from ALB SG)
    aws_cloudwatch_log_group.elasticsearch/kibana
    aws_ecs_task_definition.elasticsearch
    aws_ecs_service.elasticsearch    (1 task, Cloud Map registered)
    aws_ecs_task_definition.kibana
    aws_lb_target_group.kibana + aws_lb_listener_rule.kibana (priority 5)
    aws_ecs_service.kibana           (1 task, Cloud Map + ALB)
    aws_ecs_task_definition.kibana_setup  (one-shot task, not auto-run)

  module.catalog_service
    aws_iam_role.execution + aws_iam_role.task
    aws_cloudwatch_log_group.app (/ecs/dev/catalog)
    aws_cloudwatch_log_group.firelens (/ecs/dev/catalog/firelens)
    aws_ecs_task_definition.this  (catalog + log_router containers)
    aws_security_group.service    (8080 from ALB SG)
    aws_lb_target_group.this + aws_lb_listener_rule.this (priority 10)
    aws_ecs_service.this          (1 task)

  module.ui_service
    (same pattern as catalog, priority 100, path /*)
```

### Log flow end-to-end

```
1. ui container writes to stdout:
   INFO  c.a.s.ui.UiApplication - Request: GET /catalogue

2. ECS intercepts stdout (awsfirelens log driver)
   → sends to log_router container via Unix socket

3. Fluent Bit (log_router) receives the record, adds metadata:
   { message: "INFO...", service: "ui", env: "dev", environment: "dev", cluster: "retail-store" }

4. Fluent Bit OUTPUT sends to Elasticsearch:
   POST http://elasticsearch.dev.local:9200/logs-ui/_doc
   { "@timestamp": "2026-04-07T...", "message": "INFO...", "service": "ui" }

5. Kibana reads from Elasticsearch:
   http://<alb-dns>/kibana → Discover → logs-* → filter by service:ui

6. Fluent Bit's own operational logs go to CloudWatch:
   /ecs/dev/ui/firelens → "flushed 3 records to Elasticsearch"
```

### Dependency graph

```
vpc ──────────────────────────────────┐
                                      │
ecs_cluster ─────────────────────┐    │
                                 │    │
alb ──────────────────────────┐  │    │
                              │  │    │
logging ─────────────────┐   │  │    │
(SSM, ES, Kibana)        │   │  │    │
                         ▼   ▼  ▼    ▼
               catalog_service, ui_service
               (need: cluster_id, subnet_ids, alb_listener_arn, elasticsearch_url)
```

Terraform's dependency graph is mostly automatic (via references), but `depends_on` makes it explicit for the logging → service ordering.

---

## 15. Common Issues & Fixes

### `Error: configuring Terraform AWS Provider: no valid credential sources found`

**Cause:** Provider trying to find real AWS credentials.
**Fix:** Add `skip_credentials_validation = true` and `access_key = "test"` to provider.

### `Error: creating ECS Task Definition: SerializationException`

**Cause:** `container_definitions` is malformed JSON.
**Fix:** Use `jsonencode()` instead of a heredoc. Run `terraform validate` before apply.

### `Error: creating ECS Service: InvalidParameterException: The provided target group does not have an associated load balancer`

**Cause:** ECS Service created before the ALB listener rule is attached.
**Fix:** `depends_on = [aws_lb_listener_rule.this]` in the ECS service.

### `Error: error creating SSM Parameter: ValidationException`

**Cause:** LocalStack SSM endpoint not configured in provider.
**Fix:** Add `ssm = "http://localhost:4566"` to the endpoints block.

### Terraform shows changes on every plan even after apply

**Cause:** LocalStack returns slightly different values than what Terraform wrote to state.
**Fix:** Expected on LocalStack free tier. Real AWS is consistent. Use `terraform refresh` to sync state.

### `count.index` vs `for_each` key confusion

```hcl
# count — deletion of subnet[0] renumbers all others → destroys everything
aws_subnet.public[0]   # delete this...
aws_subnet.public[1]   # ...and this becomes public[0] — Terraform destroys and recreates it

# for_each — stable keys, safe partial deletes
aws_subnet.public["us-east-1a"]   # delete only this, others unchanged
```

Use `for_each` when items can be individually added/removed.
Use `count` for homogeneous resources where order is stable (subnets across AZs in order).

### ES container keeps restarting (OOMKilled)

**Cause:** ES heap exceeds container memory limit.
**Fix:** `ES_JAVA_OPTS="-Xms512m -Xmx512m"` must be ≤ half of `es_memory` (2048MB).
Rule: heap = memory / 2, never exceed 31GB (JVM compressed pointers limit).

### FireLens sidecar fails to start

**Cause:** Custom Fluent Bit config file path doesn't exist in container.
**Fix:** When using `config-file-value`, the file must exist at that path in the image.
Alternative: use the AWS-managed default config (remove `firelensConfiguration.options`).

---

## 16. Interview Q&A

### Terraform Basics

**Q: What is the difference between `terraform plan` and `terraform apply`?**

`plan` is a dry run — it calculates what changes would be made (creates, updates, deletes) and shows a diff, but makes no changes to infrastructure. `apply` executes those changes. In CI/CD you typically run `plan` on PRs for review, then `apply` on merge to main. This mirrors the "build artifact, then deploy" pattern.

---

**Q: What is Terraform state and why is it important?**

State is Terraform's mapping between your HCL resource names (e.g. `aws_vpc.main`) and real infrastructure IDs (e.g. `vpc-0abc123`). Without state, Terraform can't know what already exists — it would try to create everything on every apply. State also stores attribute values (like subnet CIDRs) so modules can reference each other's outputs without making live API calls.

---

**Q: What is the difference between a local and remote backend?**

Local: `terraform.tfstate` lives on disk. Simple, but only one person can run Terraform (no locking, no sharing). Remote (S3 + DynamoDB): state is stored in S3 (durable, versioned), DynamoDB table provides locking to prevent two `apply` runs simultaneously. Teams always use remote backends. LocalStack supports both.

---

**Q: What happens if two people run `terraform apply` at the same time?**

With a local backend: both reads happen before either write — the second writer wins and the first writer's changes are lost (state corruption). With a remote backend (S3 + DynamoDB locking): the second apply fails immediately with "Error acquiring the state lock". It waits or fails until the first apply releases the lock.

---

**Q: What is `terraform import` used for?**

When you have existing infrastructure that wasn't created by Terraform, `import` brings it into state so Terraform can manage it going forward. You write the HCL resource definition, then run `terraform import aws_vpc.main vpc-0abc123`. After import, `terraform plan` should show no changes if your HCL matches reality.

---

### Modules

**Q: What is the difference between the root module and a child module?**

The root module is the directory where you run `terraform apply` (e.g. `environments/dev/`). Child modules are directories called via `module` blocks (e.g. `modules/vpc/`). Child modules don't have their own state — they're part of the calling root module's state. A root module's providers are inherited by all child modules.

---

**Q: Why use modules instead of putting everything in one `main.tf`?**

Three reasons: (1) **Reuse** — the same VPC configuration can be called from dev, staging, and prod with different variables. (2) **Encapsulation** — callers don't need to know how 15 subnet/route table/IGW resources are wired together, they just get `vpc_id` and `subnet_ids` as outputs. (3) **Testability** — you can apply just the VPC module and verify it works before building on top of it.

---

**Q: How do you pass data between modules?**

Through outputs and module inputs. Module A defines an `output "vpc_id"`. The root module passes it to Module B as `vpc_id = module.a.vpc_id`. Terraform builds a dependency graph — if Module B references Module A's output, it automatically applies Module A first.

---

### AWS / ECS

**Q: What is the difference between a Task Definition and a Task in ECS?**

Task Definition = the recipe (Docker image, CPU, memory, port mappings, environment variables, log configuration). Think of it like a Kubernetes Pod spec or a Docker Compose service definition. A Task = one running instance of that recipe, analogous to a Kubernetes Pod. An ECS Service manages N tasks, replaces failed ones, and registers healthy ones with the ALB.

---

**Q: What is the difference between the ECS Execution Role and the Task Role?**

Execution Role: used by the ECS agent (infrastructure) to pull Docker images from ECR, push logs to CloudWatch, and read SSM parameters. Always needs `AmazonECSTaskExecutionRolePolicy`. Task Role: assumed by your application code at runtime. This is where you grant S3 access, DynamoDB access, SQS access — whatever the app needs to call AWS APIs. Separate roles = least privilege. A logging sidecar doesn't need S3 access; the orders service doesn't need ECR access.

---

**Q: Why does ECS Fargate use `target_type = "ip"` for ALB target groups?**

In EC2 launch type, tasks run on instances, so the ALB registers the instance ID. In Fargate, each task gets its own ENI (Elastic Network Interface) with a private IP — there's no EC2 instance. The ALB registers the task's private IP directly. This is called `ip` target type and is required for `awsvpc` network mode.

---

**Q: Why can't you run multi-node Elasticsearch on Fargate?**

Three blockers: (1) **Storage:** Fargate containers use ephemeral storage — if a task is replaced, data is lost. Multi-node ES requires persistent EBS volumes per node (only possible with EC2 launch type). (2) **Node discovery:** ES nodes must know each other's IPs at startup. Fargate task IPs are dynamic and not known before the task starts. (3) **Kernel settings:** ES requires `vm.max_map_count=262144` via sysctl, which requires privileged containers. Fargate doesn't support privileged containers. Solution: single-node ES on Fargate, or AWS OpenSearch Service (managed).

---

### Logging / EFK

**Q: What is FireLens and how does it differ from Filebeat on Kubernetes?**

FireLens is ECS's log routing mechanism. It runs Fluent Bit (or Fluentd) as a sidecar container in your task. The app container uses `logDriver: awsfirelens` — ECS intercepts stdout and sends it to the Fluent Bit sidecar via Unix socket. Fluent Bit then routes logs to any destination (CloudWatch, Elasticsearch, S3, Kinesis).

Filebeat on Kubernetes runs as a DaemonSet (one pod per node). It reads log files from `/var/log/containers/` on the host. Filebeat is external to the app pods. FireLens is internal (sidecar). The key architectural difference: DaemonSet = one collector per node (shared); FireLens sidecar = one collector per task (isolated, more overhead but no host access needed).

---

**Q: Why is `essential: false` used on the FireLens sidecar container?**

If `essential: true` (the default), any container crash kills the entire task and triggers a task replacement. For logging sidecars, this would mean a Fluent Bit crash (e.g. from ES being temporarily down) would take down your application. With `essential: false`, the sidecar can crash without affecting the app. Logs are lost during the outage, but the service keeps running. This matches the K8s behaviour — a DaemonSet pod crash doesn't affect application pods.

---

**Q: How do ECS services discover each other without Kubernetes DNS?**

AWS Cloud Map. You create a private DNS namespace (e.g. `dev.local`) and register each ECS Service with it. When Cloud Map registers a task, it creates an A record (`catalog.dev.local → 10.0.10.5`). When ECS replaces a task, Cloud Map automatically updates the DNS. Fluent Bit sidecars reach Elasticsearch at `elasticsearch.dev.local:9200`. Equivalent to Kubernetes ClusterIP Services which give you stable DNS names for pods.

---

**Q: What is the purpose of the SSM Parameter Store in the Fluent Bit configuration?**

Instead of baking the Fluent Bit config into the Docker image (which would require rebuilding the image to change log routing), we store the config in SSM. The task execution role has `ssm:GetParameter` permission. At task startup, ECS fetches the parameter and injects it as an environment variable or mounts it. This means you can update the Fluent Bit config (e.g. change the ES index pattern) by updating the SSM parameter and restarting the task — no Docker image change needed. It also lets different environments have different configs (`/dev/fluent-bit/config` vs `/prod/fluent-bit/config`).

---

**Q: Walk me through the log flow from app container to Kibana.**

1. App container writes to stdout (e.g. `INFO - GET /catalogue 200`)
2. ECS intercepts stdout because `logDriver` is `awsfirelens` (not the default json-file)
3. ECS sends the log record to the `log_router` container in the same task via Unix socket
4. Fluent Bit applies the `[FILTER]` rule, adding `environment=dev` to the record
5. Fluent Bit `[OUTPUT]` POSTs to `http://elasticsearch.dev.local:9200/logs-catalog/_doc`
6. Elasticsearch indexes the document under the `logs-catalog` index
7. Kibana's `logs-*` data view covers this index
8. User opens `http://<alb>/kibana → Discover → filter service=catalog`

Fluent Bit's own operational logs (step 3-5 errors) go to CloudWatch Logs via `awslogs` driver on the sidecar — not via FireLens (that would be circular).

---

### Multi-Environment

**Q: Why use separate Terraform root modules per environment instead of workspaces?**

Workspaces share the same Terraform code but use different state files. They work well when environments are truly identical (same resource types, just different variable values). In practice, prod often needs fundamentally different configuration: different providers (prod may use real AWS, dev uses LocalStack), different modules enabled (prod has VPN, dev doesn't), different security controls. Separate root modules make these differences explicit in code and give each environment its own isolated state with no risk of a dev `apply` touching prod state.

---

**Q: Why do dev/staging/prod use different VPC CIDRs?**

To prevent CIDR overlap if VPC peering or Transit Gateway is ever added. If all environments use `10.0.0.0/16`, you can never peer them (peered VPCs can't have overlapping CIDRs). Distinct CIDRs (dev: `10.0/16`, staging: `10.1/16`, prod: `10.2/16`) means cross-environment connectivity is possible without redesigning. It also makes troubleshooting easier — a packet from `10.2.10.5` is clearly from prod.

---

**Q: How does Terraform handle dependencies between modules?**

Automatically through references: if `module.catalog_service` references `module.logging.elasticsearch_url`, Terraform knows to create the logging module first. For less obvious dependencies (like "wait for the ECS service to be healthy before running the setup job"), you use explicit `depends_on`:
```hcl
module "catalog_service" {
  depends_on = [module.logging]
}
```
Terraform builds a directed acyclic graph (DAG) and applies resources in parallel where there are no dependencies, sequentially where there are.

---

*See also: DEVOPS_NOTES.md (Docker/CI), K8S_HELM_NOTES.md (Kubernetes/Helm), OBSERVABILITY_NOTES.md (Prometheus/Grafana/ELK)*

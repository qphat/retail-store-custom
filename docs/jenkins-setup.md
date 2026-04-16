# Jenkins CI/CD Setup Guide

Jenkins runs on an EC2 instance provisioned by Terraform.
No manual SSH steps — all tools are installed by `user_data.sh` at first boot.

---

## 1. Provision Jenkins with Terraform

```bash
# Set your IP first — restricts Jenkins UI and SSH to your machine only
MY_IP=$(curl -sf ifconfig.me)/32
echo "Your IP: $MY_IP"

# Edit terraform.tfvars
cd terraform/environments/eks-dev
# Replace 0.0.0.0/0 with your IP in jenkins_allowed_cidr

terraform init
terraform apply
```

After `terraform apply` completes, two outputs give you everything you need:

```bash
terraform output jenkins_url
# → http://1.2.3.4:8080

terraform output jenkins_initial_password
# → ssh ubuntu@1.2.3.4 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

**Wait ~3 minutes** after `apply` before opening Jenkins — the `user_data.sh` bootstrap
(Jenkins install + tool installs + kubeconfig setup) takes about 2-3 min on t3.medium.

---

## 2. Initial Admin Password

Run the command from the output above:

```bash
ssh ubuntu@<EIP> 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

Paste the 32-character hex string into the Jenkins UI setup wizard.

---

## 3. Install Plugins

In the setup wizard, choose **"Select plugins to install"** then install:

### Must-have (search by name)

| Plugin | Why |
|---|---|
| Pipeline | Declarative Jenkinsfile support |
| Git | SCM checkout |
| GitHub Branch Source | Multibranch pipelines + PR detection |
| Docker Pipeline | `docker.build()`, `docker.withRegistry()` |
| Lockable Resources | `lock()` step — prevents concurrent deploys |
| AnsiColor | Colored terminal output |
| Timestamper | Timestamps per log line |
| NodeJS | Node.js tool configuration |

### Optional (nice to have)

| Plugin | Why |
|---|---|
| Blue Ocean | Modern pipeline visualization UI |
| Build Timeout | Kill stuck builds automatically |

After the wizard, go to **Manage Jenkins → Plugins** to add anything you missed.

---

## 4. Configure Tools

**Manage Jenkins → Tools**

### JDK
- Name: `jdk-21`
- Install automatically: Adoptium Temurin 21

### NodeJS
- Name: `node-22`
- Version: `22.x`
- Install automatically: ✓

### Go
- Name: `go-1.21`
- Version: `1.21`
- Install automatically: ✓

> **Note:** The Jenkinsfile `buildScanPush()` function runs `docker build` which compiles
> inside the Dockerfile — tool setup is only needed if you add unit test stages.

---

## 5. Configure Credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credential**

### Docker Hub

| Field | Value |
|---|---|
| Kind | Username with password |
| ID | `docker-hub` ← must match Jenkinsfile exactly |
| Username | your Docker Hub username |
| Password | your Docker Hub password or access token |

> AWS credentials are **not needed** — the EC2 IAM role attached to the Jenkins instance
> handles all AWS API calls automatically (ECR, EKS, ECS, S3, DynamoDB).

---

## 6. Create the Pipeline Job

1. **New Item** → name it `retail-store` → **Multibranch Pipeline**
2. **Branch Sources** → Add source → **GitHub**
   - Credentials: Add GitHub token (or leave empty for public repos)
   - Repository URL: `https://github.com/qphat/retail-store-custom`
3. **Build Configuration**
   - Mode: by Jenkinsfile
   - Script Path: `Jenkinsfile`
4. **Scan Multibranch Pipeline Triggers** → check "Periodically if not otherwise run" → `1 minute`
5. Click **Save** → Jenkins immediately scans and discovers `main` + `feat/eks` branches

---

## 7. Configure GitHub Webhook

Push events trigger Jenkins immediately instead of waiting for polling.

1. Go to GitHub repo → **Settings → Webhooks → Add webhook**
2. Fill in:

| Field | Value |
|---|---|
| Payload URL | `http://<EIP>:8080/github-webhook/` |
| Content type | `application/json` |
| Events | **Just the push event** |

3. Click **Add webhook** → GitHub sends a ping → verify green tick

---

## 8. First Pipeline Run

Push any change to `src/catalog/` on `feat/eks` branch:

```bash
git checkout feat/eks
echo "# trigger" >> src/catalog/README.md
git add src/catalog/README.md
git commit -m "test: trigger Jenkins build"
git push origin feat/eks
```

Watch the pipeline at `http://<EIP>:8080/job/retail-store/job/feat%2Feks/`

Expected stages:
```
✓ Detect Changes     — BUILD_CATALOG=true, others=false
✓ Build & Scan       — catalog only (parallel, others skipped)
✓ Deploy to EKS      — helm upgrade --install retail-store
✓ Smoke Test         — all 6 endpoints 200
```

---

## 9. Manual Terraform Run

To run Terraform from Jenkins (optional):

1. Open the `retail-store` pipeline
2. Click **Build with Parameters**
3. Set `TF_ENV = eks-dev`, `TF_ACTION = plan`
4. Review the plan in the **Artifacts** section
5. Re-run with `TF_ACTION = apply` to apply

Non-`eks-dev` environments show an `input` gate — someone must click **Apply** in the
Jenkins UI before Terraform proceeds.

---

## 10. GitHub Actions vs Jenkins — Quick Reference

| Concept | GitHub Actions | Jenkins |
|---|---|---|
| Change detection | `dorny/paths-filter` | `git diff --name-only HEAD~1` |
| Matrix builds | `strategy.matrix` | `parallel { stage(...) }` |
| Concurrency guard | `cancel-in-progress: false` | `lock(resource: 'eks-deploy')` |
| AWS auth | OIDC (federated) | EC2 IAM Instance Profile |
| Push image | SHA + latest | SHA tag only |
| Retry | `nick-fields/retry` | `retry(3) { ... }` |
| Manual approval | GitHub Environment gates | `input` step |
| Secrets | GitHub Secrets | Jenkins Credentials store |
| Terraform approval | `environment:` protection rule | `input` step |

---

## Troubleshooting

### Jenkins not accessible after `terraform apply`

Bootstrap takes 2-3 minutes. Check progress:

```bash
ssh ubuntu@<EIP> 'sudo tail -f /var/log/cloud-init-output.log'
```

### `docker: command not found` in pipeline

Jenkins user wasn't added to the docker group at boot. Fix:

```bash
ssh ubuntu@<EIP>
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

### `kubectl: error: cluster ... not found`

The kubeconfig was written at boot before EKS was ready. Re-run:

```bash
ssh ubuntu@<EIP>
sudo -u jenkins aws eks update-kubeconfig \
  --name eks-dev-retail-store \
  --region us-east-1 \
  --kubeconfig /var/lib/jenkins/.kube/config
```

### Trivy scan fails — false positive

To suppress a known false positive in a module, add a `.trivyignore` file in the service dir:

```
# src/catalog/.trivyignore
CVE-2023-XXXXX   # reason: not reachable in our build
```

### Lockable Resources plugin not installed

The `lock()` step fails with "No such DSL method". Install the **Lockable Resources** plugin
from Manage Jenkins → Plugins, then restart Jenkins.

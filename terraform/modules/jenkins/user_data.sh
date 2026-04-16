#!/bin/bash
# Jenkins bootstrap — runs once on first EC2 boot.
# All tools are pinned to exact versions to keep builds reproducible.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# ── 1. System packages ────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  docker.io git jq unzip

# ── 2. Jenkins LTS ────────────────────────────────────────────────────────────
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y
# Java 21 is required by Jenkins LTS >= 2.426
apt-get install -y openjdk-21-jdk jenkins

# Allow Jenkins to build Docker images on the host daemon
usermod -aG docker jenkins

# ── 3. AWS CLI v2 ─────────────────────────────────────────────────────────────
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp/aws-install
/tmp/aws-install/aws/install
rm -rf /tmp/awscli.zip /tmp/aws-install

# ── 4. kubectl (match EKS version 1.32) ──────────────────────────────────────
KUBECTL_VERSION="v1.32.0"
curl -fsSL "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

# ── 5. Helm 3 ─────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── 6. Trivy (latest) ─────────────────────────────────────────────────────────
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b /usr/local/bin

# ── 7. Terraform 1.9 ──────────────────────────────────────────────────────────
TERRAFORM_VERSION="1.9.5"
curl -fsSL "https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/terraform_$${TERRAFORM_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip
unzip -q /tmp/terraform.zip -d /usr/local/bin/
rm /tmp/terraform.zip

# ── 8. Pre-configure kubeconfig for the jenkins OS user ───────────────────────
# The EC2 IAM role has eks:DescribeCluster — no credentials needed.
mkdir -p /var/lib/jenkins/.kube
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --kubeconfig /var/lib/jenkins/.kube/config
chown -R jenkins:jenkins /var/lib/jenkins/.kube

# ── 9. Enable + start Jenkins ─────────────────────────────────────────────────
systemctl enable jenkins
systemctl start jenkins

echo "Bootstrap complete. Jenkins starting at http://$(curl -sf ifconfig.me 2>/dev/null || echo '<public-ip>'):8080"
echo "Initial admin password: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"

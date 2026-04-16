// ─────────────────────────────────────────────────────────────────────────────
// Retail Store — Jenkins Declarative Pipeline
//
// Mirrors .github/workflows/eks-deploy.yml logic:
//   detect-changes → build + Trivy scan + push (SHA tag only) → Helm deploy → smoke test
//
// Runs on: Jenkins controller EC2 (provisioned by terraform/modules/jenkins)
// Auth:    EC2 IAM role (no static credentials stored in Jenkins)
// Docker:  Host Docker socket mounted — no DIND needed
// ─────────────────────────────────────────────────────────────────────────────

pipeline {
    agent any

    // ── Parameters (for manual runs + Terraform stage) ────────────────────────
    parameters {
        choice(
            name: 'TF_ENV',
            choices: ['none', 'eks-dev'],
            description: 'Run Terraform for this environment (none = skip)'
        )
        choice(
            name: 'TF_ACTION',
            choices: ['plan', 'apply'],
            description: 'Terraform action (only used when TF_ENV != none)'
        )
    }

    // ── Environment variables ─────────────────────────────────────────────────
    environment {
        AWS_REGION      = 'us-east-1'
        IMAGE_PREFIX    = 'koomi1/retail-app'   // Docker Hub image prefix
        IMAGE_REGISTRY  = 'koomi1'              // passed to helm --set imageRegistry
        EKS_CLUSTER     = 'eks-dev-retail-store'
        HELM_CHART      = 'helm/retail-store'
        HELM_RELEASE    = 'retail-store'
    }

    options {
        // Timestamp every log line
        timestamps()
        // Colour ANSI codes in console (requires AnsiColor plugin)
        ansiColor('xterm')
        // Keep last 10 builds
        buildDiscarder(logRotator(numToKeepStr: '10'))
        // Global timeout — safety net
        timeout(time: 60, unit: 'MINUTES')
    }

    stages {

        // ── Stage 1: Detect which services changed ────────────────────────────
        // Uses git diff against the previous commit.
        // Sets BUILD_<SERVICE>=true/false env vars consumed by later stages.
        stage('Detect Changes') {
            steps {
                script {
                    def base = sh(
                        script: 'git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD',
                        returnStdout: true
                    ).trim()

                    def services = ['catalog', 'cart', 'orders', 'checkout', 'ui']
                    def anyChanged = false

                    services.each { svc ->
                        def count = sh(
                            script: "git diff --name-only ${base} HEAD -- src/${svc}/ helm/ | wc -l",
                            returnStdout: true
                        ).trim().toInteger()

                        def changed = count > 0
                        env["BUILD_${svc.toUpperCase()}"] = changed ? 'true' : 'false'
                        if (changed) {
                            anyChanged = true
                            echo "  ✔ ${svc} — changed (${count} files)"
                        } else {
                            echo "  – ${svc} — no changes"
                        }
                    }

                    env.ANY_CHANGED = anyChanged ? 'true' : 'false'
                    echo "Changed services detected: ${anyChanged ? 'yes' : 'none'}"
                }
            }
        }

        // ── Stage 2: Build, Scan, Push (parallel per service) ────────────────
        // Each service builds its Docker image, scans with Trivy for CRITICAL CVEs,
        // then pushes :{GIT_COMMIT} SHA tag. No :latest — SHA is immutable and
        // traceable to the exact commit that produced it.
        stage('Build & Scan') {
            when { environment name: 'ANY_CHANGED', value: 'true' }
            parallel {

                stage('catalog') {
                    when { environment name: 'BUILD_CATALOG', value: 'true' }
                    steps {
                        script { buildScanPush('catalog', 'go') }
                    }
                }

                stage('cart') {
                    when { environment name: 'BUILD_CART', value: 'true' }
                    steps {
                        script { buildScanPush('cart', 'java') }
                    }
                }

                stage('orders') {
                    when { environment name: 'BUILD_ORDERS', value: 'true' }
                    steps {
                        script { buildScanPush('orders', 'java') }
                    }
                }

                stage('checkout') {
                    when { environment name: 'BUILD_CHECKOUT', value: 'true' }
                    steps {
                        script { buildScanPush('checkout', 'node') }
                    }
                }

                stage('ui') {
                    when { environment name: 'BUILD_UI', value: 'true' }
                    steps {
                        script { buildScanPush('ui', 'java') }
                    }
                }

            } // parallel
        }

        // ── Stage 3: Deploy to EKS via Helm ──────────────────────────────────
        // Runs only on main / feat/eks branches (not PRs).
        // lock() prevents two concurrent Helm deploys — same as
        // cancel-in-progress: false in GitHub Actions.
        stage('Deploy to EKS') {
            when {
                anyOf {
                    branch 'main'
                    branch 'feat/eks'
                }
            }
            options {
                // Queue concurrent deploys — never cancel mid-deploy
                lock(resource: 'eks-deploy', inversePrecedence: false)
            }
            steps {
                // EC2 IAM role handles AWS auth — no credentials needed
                sh '''
                    aws eks update-kubeconfig \
                      --name ${EKS_CLUSTER} \
                      --region ${AWS_REGION}
                    kubectl get nodes
                '''

                // Ingress controller — idempotent, safe to run every deploy
                sh '''
                    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
                    helm repo update
                    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
                      --namespace ingress-nginx \
                      --create-namespace \
                      --set controller.service.type=LoadBalancer \
                      --wait \
                      --timeout 5m
                '''

                // App deploy — SHA tag pinned, no :latest ambiguity
                sh '''
                    helm upgrade --install ${HELM_RELEASE} ${HELM_CHART} \
                      --set imageTag=${GIT_COMMIT} \
                      --set imageRegistry=${IMAGE_REGISTRY} \
                      --wait \
                      --timeout 10m
                '''

                sh '''
                    echo "=== Pods ==="
                    kubectl get pods -o wide
                    echo ""
                    echo "=== Ingress ==="
                    kubectl get ingress
                    echo ""
                    echo "=== Services ==="
                    kubectl get svc
                '''
            }
        }

        // ── Stage 4: Smoke Test ───────────────────────────────────────────────
        // Waits for the NGINX ingress to get an ALB address, then checks every
        // service endpoint. Retries each check up to 10 times (15s gap = ~2.5 min).
        stage('Smoke Test') {
            when {
                anyOf {
                    branch 'main'
                    branch 'feat/eks'
                }
            }
            steps {
                sh '''
                    echo "Waiting for ingress address..."
                    for i in $(seq 1 20); do
                        ADDR=$(kubectl get ingress ${HELM_RELEASE} \
                          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
                        if [ -n "$ADDR" ]; then
                            echo "Ingress address: $ADDR"
                            break
                        fi
                        echo "  attempt $i: not ready yet — waiting 15s..."
                        sleep 15
                    done

                    if [ -z "$ADDR" ]; then
                        echo "ERROR: Ingress address not ready after 5 minutes"
                        exit 1
                    fi

                    BASE="http://$ADDR"
                    FAILED=0

                    check() {
                        local name=$1 url=$2 expected=$3
                        for i in $(seq 1 10); do
                            STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || echo "000")
                            if [ "$STATUS" = "$expected" ]; then
                                echo "✓ $name → $STATUS"
                                return 0
                            fi
                            echo "  $name attempt $i: got $STATUS, expected $expected — retrying in 15s..."
                            sleep 15
                        done
                        echo "✗ $name FAILED after 10 attempts"
                        FAILED=$((FAILED + 1))
                    }

                    check "ui"       "$BASE/"                    "200"
                    check "catalog"  "$BASE/catalogue"           "200"
                    check "cart"     "$BASE/api/cart/health"     "200"
                    check "orders"   "$BASE/api/orders/health"   "200"
                    check "checkout" "$BASE/api/checkout/health" "200"
                    check "kibana"   "$BASE/kibana/api/status"   "200"

                    if [ $FAILED -gt 0 ]; then
                        echo ""
                        echo "✗ $FAILED service(s) failed smoke test"
                        exit 1
                    fi

                    echo ""
                    echo "✓ All services healthy"
                    echo "App URL: $BASE"
                '''
            }
        }

        // ── Stage 5: Terraform (optional, parameterized) ──────────────────────
        // Triggered by setting TF_ENV != 'none' on a manual build.
        // apply requires an interactive approval for non-dev environments.
        stage('Terraform') {
            when { not { environment name: 'TF_ENV', value: 'none' } }
            stages {

                stage('Lint') {
                    steps {
                        sh 'terraform fmt -check -recursive terraform/'
                        sh "cd terraform/environments/${params.TF_ENV} && terraform init -backend=false && terraform validate"
                    }
                }

                stage('Plan') {
                    steps {
                        sh """
                            cd terraform/environments/${params.TF_ENV}
                            terraform init -lock-timeout=5m
                            terraform plan -no-color -lock-timeout=5m -out=tfplan | tee plan.txt
                        """
                        // Archive plan output for review
                        archiveArtifacts artifacts: "terraform/environments/${params.TF_ENV}/plan.txt"
                    }
                }

                stage('Apply') {
                    when { expression { params.TF_ACTION == 'apply' } }
                    steps {
                        script {
                            // Non-dev environments require manual approval
                            if (params.TF_ENV != 'eks-dev') {
                                input message: "Apply Terraform to ${params.TF_ENV}?",
                                      ok: 'Apply',
                                      submitter: 'admin'
                            }
                        }
                        sh """
                            cd terraform/environments/${params.TF_ENV}
                            terraform apply -auto-approve -lock-timeout=5m tfplan
                        """
                    }
                }

            } // nested stages
        }

    } // stages

    post {
        success {
            echo "Pipeline completed successfully."
        }
        failure {
            echo "Pipeline FAILED — check logs above."
            // Add Slack/email notification here if needed
        }
        always {
            // Clean up local Docker images to avoid disk exhaustion
            sh '''
                docker image prune -f --filter "until=24h" || true
            '''
        }
    }

} // pipeline

// ── Helper function: build → scan → push ─────────────────────────────────────
// Called per-service inside parallel stages.
// Pushes only on main / feat/eks branches, never on PRs.
def buildScanPush(String service, String runtime) {
    def image = "${env.IMAGE_PREFIX}-${service}:${env.GIT_COMMIT}"

    echo "Building ${service} (${runtime})..."

    sh "docker build -t ${image} src/${service}/"

    echo "Scanning ${service} with Trivy..."
    sh """
        trivy image \
          --exit-code 1 \
          --severity CRITICAL \
          --ignore-unfixed \
          --no-progress \
          ${image}
    """

    def onDeployBranch = (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'feat/eks')
    if (onDeployBranch) {
        echo "Pushing ${image}..."
        // Docker Hub credentials stored in Jenkins Credentials store (ID: docker-hub)
        withCredentials([usernamePassword(
            credentialsId: 'docker-hub',
            usernameVariable: 'DOCKER_USER',
            passwordVariable: 'DOCKER_PASS'
        )]) {
            sh """
                echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                docker push ${image}
            """
        }
    } else {
        echo "PR build — scan passed, skipping push."
    }
}

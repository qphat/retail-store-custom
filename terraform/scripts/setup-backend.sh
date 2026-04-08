#!/usr/bin/env bash
# Creates the S3 bucket and DynamoDB table for Terraform remote state.
# Run this ONCE before the first terraform init.
#
# Usage: ./scripts/setup-backend.sh [region]
#   region defaults to us-east-1

set -euo pipefail

REGION="${1:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="retail-store-tf-state-${ACCOUNT_ID}"
TABLE="retail-store-tf-lock"

echo "Account : $ACCOUNT_ID"
echo "Region  : $REGION"
echo "Bucket  : $BUCKET"
echo "Table   : $TABLE"
echo ""

# ── S3 bucket ──────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "✓ Bucket already exists: $BUCKET"
else
  echo "Creating bucket: $BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    # us-east-1 does not accept a LocationConstraint — it's the default
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi

  # Versioning — keeps every state revision, allows rollback
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  # Encryption at rest
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }]
    }'

  # Block all public access — state files must never be public
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "✓ Bucket created and configured"
fi

# ── DynamoDB lock table ────────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  echo "✓ DynamoDB table already exists: $TABLE"
else
  echo "Creating DynamoDB table: $TABLE"
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"

  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "✓ DynamoDB table created"
fi

# ── Patch backend.tf files with the actual bucket name ────────────────────────
echo ""
echo "Updating backend.tf files with bucket: $BUCKET"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for env in dev staging prod; do
  BACKEND="$REPO_ROOT/terraform/environments/$env/backend.tf"
  if [ -f "$BACKEND" ]; then
    sed -i "s|bucket.*=.*\"retail-store-tf-state\"|bucket         = \"$BUCKET\"|" "$BACKEND"
    echo "  ✓ $env/backend.tf"
  fi
done

echo ""
echo "Done. Next steps:"
echo ""
echo "  cd terraform/environments/dev"
echo "  terraform init"
echo "  terraform plan"

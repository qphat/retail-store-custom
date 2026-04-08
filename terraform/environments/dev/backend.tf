terraform {
  backend "s3" {
    bucket         = "retail-store-tf-state"   # set by scripts/setup-backend.sh
    key            = "retail-store/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "retail-store-tf-lock"
    encrypt        = true
  }
}

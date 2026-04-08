terraform {
  backend "s3" {
    bucket         = "retail-store-tf-state-630022771147"   # set by scripts/setup-backend.sh
    key            = "retail-store/dev/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}

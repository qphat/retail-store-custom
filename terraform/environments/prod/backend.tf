terraform {
  backend "s3" {
    bucket         = "retail-store-tf-state-630022771147"
    key            = "retail-store/prod/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}

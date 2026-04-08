terraform {
  backend "s3" {
    bucket         = "retail-store-tf-state"
    key            = "retail-store/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "retail-store-tf-lock"
    encrypt        = true
  }
}

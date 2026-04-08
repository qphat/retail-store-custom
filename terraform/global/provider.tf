terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # Store global state separately from environment state
  backend "s3" {
    bucket         = "retail-store-tf-state"   # patched by scripts/setup-backend.sh
    key            = "retail-store/global/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "retail-store-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # LocalStack — any non-empty credentials work
  access_key = "test"
  secret_key = "test"

  # Prevent the provider from making real AWS validation calls
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # Route every service API call to LocalStack
  endpoints {
    ecs              = "http://localhost:4566"
    ec2              = "http://localhost:4566"
    iam              = "http://localhost:4566"
    logs             = "http://localhost:4566"
    ssm              = "http://localhost:4566"
    elbv2            = "http://localhost:4566"
    servicediscovery = "http://localhost:4566"
  }
}

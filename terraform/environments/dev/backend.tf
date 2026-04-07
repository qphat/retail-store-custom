# Local state — simple for LocalStack learning.
# Replace with S3 backend when moving to real AWS:
#   backend "s3" {
#     bucket         = "my-tf-state"
#     key            = "retail-store/dev/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "terraform-locks"
#   }
terraform {
  backend "local" {
    path = "dev.tfstate"
  }
}

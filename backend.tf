terraform {
  backend "s3" {
    bucket         = "devops-projects-terraform-backends"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
  }
}



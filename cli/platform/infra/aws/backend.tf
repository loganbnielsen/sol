terraform {
  backend "s3" {
    bucket         = "sol-qual2-tfstate-00e2a443"
    key            = "sol/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sol-qual2-tflock-00e2a443"
    encrypt        = true
  }
}

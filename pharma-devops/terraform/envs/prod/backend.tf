terraform {
  backend "s3" {
    bucket         = "pharma-tf-state"
    key            = "envs/prod/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "pharma-tf-lock"
    encrypt        = true
  }
}

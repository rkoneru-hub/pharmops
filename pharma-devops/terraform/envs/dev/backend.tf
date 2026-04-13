terraform {
  backend "s3" {
    bucket         = "pharma-tf-state-972024102569"
    key            = "envs/dev/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "pharma-tf-locks"
    encrypt        = true
  }
}

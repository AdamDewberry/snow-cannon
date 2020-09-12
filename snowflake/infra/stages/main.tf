terraform {
  required_version = ">= 0.12.29"

  backend "s3" {
  }
}

provider "snowflake" {
  account = var.snowflake_account
  region  = var.snowflake_region
  role    = "SYSADMIN"
}

provider "aws" {
  region  = var.aws_region
  version = "~> 3.5.0"
}

module "stage_example" {
  source         = "../modules/stages-module/"
  s3_bucket_name = "snow-cannon-data-lake"
  s3_path        = "key1/key2"
  database       = "ANALYTICS"
  schema         = "PUBLIC"
}

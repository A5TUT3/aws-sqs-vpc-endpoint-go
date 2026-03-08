# This block tells Terraform which providers (plugins) we need to download
terraform {
  required_providers {
    aws = {
      # This is the official AWS provider maintained by HashiCorp
      source  = "hashicorp/aws"
      # ~> 5.0 means "use version 5.x but not 6.0 or higher" (safe upgrades only)
      version = "~> 5.0"
    }
  }
}

# This configures the AWS provider with settings that apply to all resources
provider "aws" {
  # We reference the region variable defined in variables.tf instead of hardcoding it
  region = var.region
}

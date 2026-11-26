terraform {
  required_version = ">= 1.9"
  # State in Postgres, with locking, one state per Terraform workspace (dev, prod). The connection
  # string comes from PG_CONN_STR. Use your organisation's remote backend instead if it has one.
  backend "pg" {}
  required_providers {
    kong-gateway = { source = "kong/kong-gateway", version = "1.4.1" }
    random       = { source = "hashicorp/random", version = "3.7.2" }
  }
}

# One Terraform workspace per environment (dev, prod); the Admin API address and the platform
# token come from the environment (TF_VAR_admin_url, TF_VAR_admin_token), never from a file.
provider "kong-gateway" {
  server_url  = var.admin_url
  admin_token = var.admin_token
}

variable "admin_url" {
  type        = string
  description = "Kong Admin API of the environment, e.g. https://kong-admin.dev.example.com"
}

variable "admin_token" {
  type        = string
  sensitive   = true
  description = "The platform pipeline's token (the ci-platform RBAC user, see platform/bootstrap)."
}

locals {
  # One workspace per team, named after the team.
  teams = { for t in yamldecode(file("${path.module}/../../teams.yaml")).teams : t.name => t }
}

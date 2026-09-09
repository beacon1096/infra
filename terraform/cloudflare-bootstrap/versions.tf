terraform {
  required_version = ">= 1.11"

  backend "kubernetes" {
    namespace     = "terraform-state"
    secret_suffix = "cloudflare-bootstrap"
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.23"
    }
  }
}

provider "cloudflare" {}

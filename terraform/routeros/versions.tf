terraform {
  required_version = ">= 1.6"

  backend "kubernetes" {
    namespace     = "terraform-state"
    secret_suffix = "routeros-rb5009"
  }

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.99.1"
    }
  }
}

provider "routeros" {}

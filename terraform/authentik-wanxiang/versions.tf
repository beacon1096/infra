terraform {
  required_version = ">= 1.11"

  backend "kubernetes" {
    namespace     = "terraform-state"
    secret_suffix = "authentik-wanxiang"
  }

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2.0"
    }
  }
}

provider "authentik" {
  url = "https://id.beaco.works"
}

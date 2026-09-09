terraform {
  required_version = ">= 1.11"

  backend "kubernetes" {
    namespace     = "terraform-state"
    secret_suffix = "unifi-wanxiang"
  }

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "= 0.55.0"
    }
  }
}

provider "unifi" {
  api_url        = "https://172.16.80.254"
  allow_insecure = true
  site           = "default"
}

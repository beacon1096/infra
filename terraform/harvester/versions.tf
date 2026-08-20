terraform {
  required_version = ">= 1.6"

  required_providers {
    harvester = {
      source = "harvester/harvester"
      # Provider now tracks the Harvester version: v1.7.x pairs with Harvester
      # 1.7.x (cluster is 1.7.1). v1.7.1 released 2026-02-12.
      version = "~> 1.7.1"
    }
  }
}

provider "harvester" {
  # Admin kubeconfig with the API server rewritten to the VIP.
  # rke2's serving cert has no VIP SAN, so terraform must skip TLS verify;
  # alternatively download a VIP kubeconfig from the Harvester UI.
  kubeconfig = var.kubeconfig
}

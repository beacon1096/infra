locals {
  permission_group_ids = {
    dns_write = "4755a26eedb94da69e1066d98aa820be"
    zone_read = "c8fed203ed3043cba015a93ad1616f1f"
    dns_read  = "82e64a83756745bbbb1c9c2701bf816b"
  }
}

resource "cloudflare_account_token" "terraform_dns" {
  account_id = var.cloudflare_account_id
  name       = "terraform-dns"
  status     = "active"

  policies = [{
    effect = "allow"
    permission_groups = [
      {
        id = local.permission_group_ids.dns_write
      },
      {
        id = local.permission_group_ids.zone_read
      },
      {
        id = local.permission_group_ids.dns_read
      },
    ]
    resources = jsonencode({
      for zone_id in var.cloudflare_dns_zone_ids :
      "com.cloudflare.api.account.zone.${zone_id}" => "*"
    })
  }]

  lifecycle {
    prevent_destroy = true
  }
}

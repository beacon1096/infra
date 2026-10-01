locals {
  mail_records = {
    beaco_mail = {
      zone_id  = var.beaco_works_zone_id
      name     = "mail.beaco.works"
      type     = "CNAME"
      content  = "shuttle.beacoworks.xyz"
      ttl      = 1
      priority = null
    }
    beaco_courier = {
      zone_id  = var.beaco_works_zone_id
      name     = "courier.beaco.works"
      type     = "CNAME"
      content  = "courier.beacoworks.xyz"
      ttl      = 1
      priority = null
    }
    beaco_mx = {
      zone_id  = var.beaco_works_zone_id
      name     = "beaco.works"
      type     = "MX"
      content  = "mail.beaco.works"
      ttl      = 1
      priority = 10
    }
    beaco_spf = {
      zone_id  = var.beaco_works_zone_id
      name     = "beaco.works"
      type     = "TXT"
      content  = "\"v=spf1 mx ip4:89.208.240.145 ip4:89.208.241.145 ra=postmaster -all\""
      ttl      = 1
      priority = null
    }
    beaco_dmarc = {
      zone_id  = var.beaco_works_zone_id
      name     = "_dmarc.beaco.works"
      type     = "TXT"
      content  = "\"v=DMARC1; p=reject; rua=mailto:postmaster@beaco.works; ruf=mailto:postmaster@beaco.works\""
      ttl      = 1
      priority = null
    }
    xyz_mail = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "mail.beacoworks.xyz"
      type     = "CNAME"
      content  = "mail.beaco.works"
      ttl      = 60
      priority = null
    }
    xyz_courier = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "courier.beacoworks.xyz"
      type     = "A"
      content  = "89.208.240.145"
      ttl      = 1
      priority = null
    }
    xyz_shuttle = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "shuttle.beacoworks.xyz"
      type     = "A"
      content  = "89.208.241.145"
      ttl      = 1
      priority = null
    }
    xyz_mx = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "beacoworks.xyz"
      type     = "MX"
      content  = "mail.beaco.works"
      ttl      = 7200
      priority = 10
    }
    xyz_spf = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "beacoworks.xyz"
      type     = "TXT"
      content  = "\"v=spf1 mx ip4:89.208.240.145 ip4:89.208.241.145 ra=postmaster -all\""
      ttl      = 1
      priority = null
    }
    xyz_dmarc = {
      zone_id  = var.beacoworks_xyz_zone_id
      name     = "_dmarc.beacoworks.xyz"
      type     = "TXT"
      content  = "\"v=DMARC1; p=reject; rua=mailto:postmaster@beacoworks.xyz; ruf=mailto:postmaster@beacoworks.xyz\""
      ttl      = 1
      priority = null
    }
  }
}

locals {
  # High-bandwidth hostnames moved off the Cloudflare Tunnel: DNS-only
  # (proxied = false) so large registry / Attic uploads never hit Cloudflare's
  # body-size limits. They are CNAMEs to this stable edge alias so the backing
  # node can change in one record instead of every hostname. The matching
  # HTTPRoutes set `external-dns.alpha.kubernetes.io/controller: none` so
  # external-dns does not fight these records.
  # IPv4 of the authoritative self-hosted Caddy edge (spec 009-caddy-edge-ingress).
  edge_ingress_ipv4 = "67.230.162.189"

  edge_records = {
    edge = {
      zone_id  = var.beaco_works_zone_id
      name     = "edge.beaco.works"
      type     = "A"
      content  = local.edge_ingress_ipv4
      ttl      = 60
      priority = null
    }
    forgejo = {
      zone_id  = var.beaco_works_zone_id
      name     = "forgejo.beaco.works"
      type     = "CNAME"
      content  = "edge.beaco.works"
      ttl      = 60
      priority = null
    }
    nix = {
      zone_id  = var.beaco_works_zone_id
      name     = "nix.beaco.works"
      type     = "CNAME"
      content  = "edge.beaco.works"
      ttl      = 60
      priority = null
    }
  }
}

resource "cloudflare_dns_record" "mail" {
  for_each = local.mail_records

  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  priority = each.value.priority
  proxied  = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "edge" {
  for_each = local.edge_records

  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  priority = each.value.priority
  proxied  = false

  lifecycle {
    prevent_destroy = true
  }
}

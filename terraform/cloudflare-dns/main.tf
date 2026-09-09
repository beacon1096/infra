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

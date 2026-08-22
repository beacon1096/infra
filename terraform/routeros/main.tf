locals {
  nixbuilder_leases = {
    nixbuilder-01 = {
      address = "172.16.101.31"
      mac     = "52:54:00:6E:01:01"
    }
    nixbuilder-02 = {
      address = "172.16.101.32"
      mac     = "52:54:00:6E:01:02"
    }
    nixbuilder-03 = {
      address = "172.16.101.33"
      mac     = "52:54:00:6E:01:03"
    }
  }
}

resource "routeros_ip_dhcp_server_lease" "nixbuilder" {
  for_each = local.nixbuilder_leases

  address     = each.value.address
  mac_address = each.value.mac
  comment     = each.key
  server      = "vlan1096-vmnet"

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = routeros_ip_dhcp_server_lease.nixbuilder["nixbuilder-01"]
  id = "*6A"
}

import {
  to = routeros_ip_dhcp_server_lease.nixbuilder["nixbuilder-02"]
  id = "*6B"
}

import {
  to = routeros_ip_dhcp_server_lease.nixbuilder["nixbuilder-03"]
  id = "*6C"
}

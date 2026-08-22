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

resource "routeros_routing_ospf_interface_template" "m920x_egress" {
  area                = "backbone-v2"
  auth                = "md5"
  auth_id             = 1
  comment             = "m920x OSPF egress"
  cost                = 10
  dead_interval       = "40s"
  disabled            = false
  hello_interval      = "10s"
  instance_id         = 0
  interfaces          = ["harvester-stor"]
  networks            = ["172.16.105.0/24"]
  priority            = 1
  retransmit_interval = "5s"
  transmit_delay      = "1s"
  type                = "broadcast"

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      auth_key,
      authentication_key,
    ]
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

import {
  to = routeros_routing_ospf_interface_template.m920x_egress
  id = "*5"
}

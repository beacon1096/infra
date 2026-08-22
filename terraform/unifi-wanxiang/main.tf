locals {
  wans = {
    internet_1 = {
      name = "Internet 1"
      type = "dhcp"
    }
    internet_2 = {
      name = "Internet 2"
      type = "dhcp"
    }
  }

  networks = {
    entrance = {
      name         = "Phylance Entrance"
      subnet       = "172.16.80.254/24"
      vlan         = null
      dhcp_enabled = true
    }
    management = {
      name         = "Phylance-01 Management"
      subnet       = "172.16.81.254/24"
      vlan         = 10
      dhcp_enabled = true
    }
    harvester_traffic = {
      name         = "Phylance-01 Harvester Traffic"
      subnet       = "172.16.84.254/24"
      vlan         = 20
      dhcp_enabled = true
    }
    legacy_vms = {
      name         = "Phylanx-01 Legacy VMs"
      subnet       = "172.16.82.254/24"
      vlan         = 30
      dhcp_enabled = true
    }
    talos_ii = {
      name         = "Phylanx-01 Talos-ii"
      subnet       = "172.16.87.254/24"
      vlan         = 87
      dhcp_enabled = true
    }
    talos_ii_n = {
      name         = "Phylanx-01 Talos-ii N"
      subnet       = "172.16.88.254/24"
      vlan         = 88
      dhcp_enabled = false
    }
  }
}

resource "unifi_wan" "managed" {
  for_each = local.wans

  name = each.value.name
  type = each.value.type

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

resource "unifi_network" "managed" {
  for_each = local.networks

  name   = each.value.name
  subnet = each.value.subnet
  vlan   = each.value.vlan

  dhcp_server = {
    enabled = each.value.dhcp_enabled
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

# The provider has no OSPF resource. Keep the live OSPF adjacency unmanaged.

import {
  to = unifi_wan.managed["internet_1"]
  id = "Internet 1"
}

import {
  to = unifi_wan.managed["internet_2"]
  id = "Internet 2"
}

import {
  to = unifi_network.managed["entrance"]
  id = "69564c1b5210c31b6308f0c5"
}

import {
  to = unifi_network.managed["management"]
  id = "6956630348bf813b52dfdbbf"
}

import {
  to = unifi_network.managed["harvester_traffic"]
  id = "695663c548bf813b52dfdbc8"
}

import {
  to = unifi_network.managed["legacy_vms"]
  id = "69e48ae5a26b86270fc4364f"
}

import {
  to = unifi_network.managed["talos_ii"]
  id = "69ef01a59f9dac028081ba8e"
}

import {
  to = unifi_network.managed["talos_ii_n"]
  id = "69f99f8357bd095bfdd7e8d7"
}

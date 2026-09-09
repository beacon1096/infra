# Harvester NixOS build/runner nodes.
#
# Terraform provisions the installer image and VM shells: fixed CPU/mem/disk,
# VLAN 1096 NIC with a pinned MAC (matching the RB5009 DHCP reservation). The
# ISO payload is uploaded separately after Terraform creates its image object.
# The OS is installed with `nixos-anywhere --flake .#<name>`, then managed by
# comin. Terraform never touches guest config.
#
# Prereqs:
#   - kubectl create namespace nix

resource "harvester_image" "installer" {
  name         = "image-nixos-installer"
  namespace    = var.namespace
  display_name = var.installer_image_display_name
  source_type  = "upload"
  checksum     = var.installer_image_checksum

  timeouts {
    create = "30m"
  }
}

resource "harvester_virtualmachine" "builder" {
  for_each = var.nodes

  name                 = each.key
  namespace            = var.namespace
  hostname             = each.key
  restart_after_update = true
  run_strategy         = "RerunOnFailure"

  cpu          = var.cpu
  memory       = var.memory
  machine_type = "q35" # empty firmware => SeaBIOS/BIOS, matches hosts/server/common
  efi          = false

  network_interface {
    name           = "nic-1"
    model          = "virtio"
    type           = "bridge"
    network_name   = var.vm_network
    mac_address    = each.value.mac
    wait_for_lease = true
  }

  # Keep the installer ISO attached as recovery media after provisioning.
  disk {
    name       = "cdrom"
    type       = "cd-rom"
    size       = "10Gi"
    bus        = "sata"
    boot_order = 2
    image      = harvester_image.installer.id
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.disk_size
    bus        = "virtio"
    boot_order = 1
  }
}

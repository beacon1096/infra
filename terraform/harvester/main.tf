# Harvester NixOS build/runner nodes.
#
# Terraform provisions the VM shells only: fixed CPU/mem/disk, VLAN 1096 NIC
# with a pinned MAC (matching the RB5009 DHCP reservation). The OS is installed
# out-of-band with `nixos-anywhere --flake .#<name>` against the installer ISO,
# then managed by comin. Terraform never touches guest config.
#
# Prereqs:
#   - kubectl create namespace nix
#   - upload the NixOS installer ISO as a VirtualMachineImage and set
#     var.installer_image to its namespace/name.

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

  # Boot the installer ISO first, then the (blank) root disk.
  disk {
    name       = "cdrom"
    type       = "cd-rom"
    bus        = "sata"
    boot_order = 1
    image      = var.installer_image
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.disk_size
    bus        = "virtio"
    boot_order = 2
  }
}

variable "kubeconfig" {
  type        = string
  description = "Path to the Harvester (VIP) kubeconfig."
  default     = "~/.kube/harvester.yaml"
}

variable "namespace" {
  type        = string
  description = "Harvester namespace for the build nodes (create it first: kubectl create ns nix)."
  default     = "nix"
}

variable "vm_network" {
  type        = string
  description = "Existing NetworkAttachmentDefinition for VLAN 1096 (the VM business net)."
  default     = "default/vmnet-rb5009"
}

variable "installer_image" {
  type        = string
  description = "namespace/name of the NixOS installer ISO VirtualMachineImage (upload it to Harvester first)."
  # e.g. "nix/image-nixos-installer" — set to the actual image id after upload.
}

variable "cpu" {
  type    = number
  default = 8
}

variable "memory" {
  type    = string
  default = "16Gi"
}

variable "disk_size" {
  type    = string
  default = "80Gi"
}

# Name → { ip, mac } — must match the RB5009 DHCP reservations.
variable "nodes" {
  type = map(object({ mac = string }))
  default = {
    "nixbuilder-01" = { mac = "52:54:00:6e:01:01" } # 172.16.101.31
    "nixbuilder-02" = { mac = "52:54:00:6e:01:02" } # 172.16.101.32
    "nixbuilder-03" = { mac = "52:54:00:6e:01:03" } # 172.16.101.33
  }
}

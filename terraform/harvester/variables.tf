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

variable "installer_image_display_name" {
  type        = string
  description = "Display name of the NixOS installer ISO uploaded to Harvester."
  default     = "nixos-minimal-26.05.20260717.293d6ab-x86_64-linux.iso"
}

variable "installer_image_checksum" {
  type        = string
  description = "SHA-512 checksum of the NixOS installer ISO."
  default     = "a31cfaabb01baeddd844d2bb30a441a2513e851e46a77a797e4d64bbbecd21570bc8aa8e014e5b16dc8cc83a2111f8a8d34d16754f85266fe996d617c8df8eac"
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

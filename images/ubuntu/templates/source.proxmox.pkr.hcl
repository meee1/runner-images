# Proxmox VE source for local runner-image builds.
# Clones a prepared Ubuntu cloud-init template (see docs/build-ubuntu-proxmox.md)
# and runs the same provisioners as the Azure build.

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type    = string
  default = "${env("PROXMOX_URL")}" // https://pve.example.com:8006/api2/json
}
variable "proxmox_username" {
  type    = string
  default = "${env("PROXMOX_USERNAME")}" // root@pam!packer
}
variable "proxmox_token" {
  type      = string
  default   = "${env("PROXMOX_TOKEN")}"
  sensitive = true
}
variable "proxmox_node" {
  type    = string
  default = "${env("PROXMOX_NODE")}"
}
variable "proxmox_insecure_tls" {
  type    = bool
  default = true // self-signed PVE certificate is the norm
}
variable "proxmox_clone_vm" {
  type    = string
  default = "ubuntu-2604-cloudinit"
}
variable "proxmox_storage_pool" {
  type    = string
  default = "local-lvm"
}
variable "proxmox_bridge" {
  type    = string
  default = "vmbr0"
}
variable "proxmox_template_name" {
  type    = string
  default = "gha-runner-ubuntu-2604"
}
variable "proxmox_cores" {
  type    = number
  default = 8
}
variable "proxmox_memory" {
  type    = number
  default = 16384
}
variable "ssh_username" {
  type    = string
  default = "packer"
}
variable "ssh_private_key_file" {
  type    = string
  default = "${env("PACKER_SSH_KEY")}"
}

source "proxmox-clone" "image" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.proxmox_insecure_tls

  clone_vm   = var.proxmox_clone_vm
  full_clone = true

  # ponytail: no `disks` block on purpose - it REPLACES the cloned disk.
  # Size the root disk on the base template instead (100G), cloud-init grows it.
  # The builder defaults scsi_controller to lsi, overriding whatever the base template had.
  scsi_controller = "virtio-scsi-single"

  cores        = var.proxmox_cores
  sockets      = 1
  memory       = var.proxmox_memory
  cpu_type     = "host"
  os           = "l26"
  machine      = "q35"
  qemu_agent   = true
  task_timeout = "15m"

  network_adapters {
    bridge = var.proxmox_bridge
    model  = "virtio"
  }

  ipconfig {
    ip = "dhcp"
  }

  template_name        = "${var.proxmox_template_name}-${var.image_version}"
  template_description = "GitHub Actions runner image, Ubuntu 26.04, built ${timestamp()}"
  cloud_init           = true
  cloud_init_storage_pool = var.proxmox_storage_pool

  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "15m"
}

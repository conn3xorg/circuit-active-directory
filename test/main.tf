# Planned and partly applied by CI on the windows-2022 and windows-2025 runners
# themselves, over loopback OpenSSH. A shared runner can't reboot or become a
# domain controller, so CI reads everything, installs AD DS, and stops there.
# ci.auto.tfvars is written by the workflow.

variable "user" {
  type = string
}

variable "key_file" {
  type = string
}

variable "host_key" {
  type = string
}

module "ad" {
  source = "../"

  domain_name  = "ci.conn3x.test"
  netbios_name = "CI"
  domain_controllers = {
    runner = {
      address  = "127.0.0.1"
      host_key = var.host_key
    }
  }
  ssh_user             = var.user
  ssh_private_key_file = var.key_file
  safe_mode_password   = "only-planned-never-applied-1A!"

  ous = {
    Lab     = { description = "CI" }
    Servers = { path = "OU=Lab" }
  }
  users = {
    alice = { path = "OU=Lab", given_name = "Alice" }
  }
  groups = {
    LabAdmins = { path = "OU=Lab", members = ["alice"] }
  }
}

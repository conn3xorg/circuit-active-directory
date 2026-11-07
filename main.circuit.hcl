# Facts confirm each host is Windows Server 2022 or 2025 before anything is installed.
data "conn3x_host" "facts" {
  for_each = merge(var.domain_controllers, var.members)

  allow_windows = true

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = self.os_family == "windows" && contains(["2022", "2025"], self.windows.release) && self.arch == "x86_64"
      error_message = "circuit-active-directory runs on x86_64 Windows Server 2022 or 2025."
    }
  }
}

locals {
  # The first domain controller by name makes the forest. The others join it.
  root   = coalesce(var.forest_root, sort(keys(var.domain_controllers))[0])
  others = { for name, h in var.domain_controllers : name => h if name != local.root }

  # The address each DC answers DNS on, inside the domain's network.
  ip      = { for name, h in var.domain_controllers : name => try(h.private_ip, h.address, h) }
  dns_dcs = concat([local.ip[local.root]], [for name in sort(keys(local.others)) : local.ip[name]])

  domain_dn  = join(",", [for label in split(".", var.domain_name) : "DC=${label}"])
  netbios    = coalesce(var.netbios_name, upper(substr(split(".", var.domain_name)[0], 0, 15)))
  admin_user = coalesce(var.domain_admin_username, "${local.netbios}\\${var.ssh_user}")
  member_ou  = var.member_ou == null ? null : "${var.member_ou},${local.domain_dn}"

  top_ous   = { for name, ou in var.ous : name => ou if ou.path == null }
  child_ous = { for name, ou in var.ous : name => ou if ou.path != null }

  # sshd answers before AD does, and ADWS on 9389 before Get-ADDomain works.
  # Seen on Azure: right after the forest's reboot, ADWS served the domain a
  # minute before the global catalog, and an OU made in that minute hung. So
  # AD counts as up once a query through the global catalog works too.
  ad_ready          = "Import-Module ActiveDirectory; $d = Get-ADDomain; Get-ADObject -Server 'localhost:3268' -Identity $d.DistinguishedName | Out-Null"
  ad_answers        = <<-PS
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
      try { ${local.ad_ready}; break }
      catch { if ((Get-Date) -gt $deadline) { throw } ; Start-Sleep -Seconds 5 }
    }
  PS
  ad_answers_unless = local.ad_ready
}

# The forest root: AD DS, a new forest, its reboot, then the directory's
# OUs, users and groups, which only a DC can make.
circuit "forest" {
  hosts = { (local.root) = var.domain_controllers[local.root] }

  # The bare name keeps working after promotion, as the domain's account.
  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = true
    timeout          = "15m"
  }

  step "ad_ds" {
    windows_feature {
      name                     = "AD-Domain-Services"
      include_management_tools = true
    }
  }

  step "forest" {
    windows_ad_forest {
      domain_name           = var.domain_name
      netbios_name          = var.netbios_name
      safe_mode_password_wo = var.safe_mode_password
    }
  }

  step "promoted" {
    windows_reboot {
      only_if_pending = true
      timeout         = "15m"
    }
  }

  step "adws" {
    windows_wait_for {
      port    = 9389
      timeout = "10m"
    }
  }

  step "ad_answers" {
    windows_powershell {
      script = local.ad_answers
      unless = local.ad_answers_unless
    }
  }

  # Itself first, then loopback, as for any DC.
  step "dns" {
    windows_dns_client {
      servers = [local.ip[local.root], "127.0.0.1"]
    }
  }

  # OUs at the top of the domain first, so OUs inside them can find them.
  step "ous" {
    for_each = local.top_ous

    windows_ad_ou {
      name        = item.key
      description = item.value.description
      protected   = item.value.protected
    }
  }

  step "child_ous" {
    for_each = local.child_ous

    windows_ad_ou {
      name        = item.key
      path        = "${item.value.path},${local.domain_dn}"
      description = item.value.description
      protected   = item.value.protected
    }
  }

  # Users before groups, so a group can find its members.
  step "users" {
    for_each = var.users

    windows_ad_user {
      name                   = item.key
      path                   = item.value.path == null ? null : "${item.value.path},${local.domain_dn}"
      upn                    = coalesce(item.value.upn, "${item.key}@${var.domain_name}")
      given_name             = item.value.given_name
      surname                = item.value.surname
      display_name           = item.value.display_name
      description            = item.value.description
      enabled                = item.value.enabled
      password_never_expires = item.value.password_never_expires
      password_wo            = try(var.user_passwords[item.key], null)
    }
  }

  step "groups" {
    for_each = var.groups

    windows_ad_group {
      name          = item.key
      path          = item.value.path == null ? null : "${item.value.path},${local.domain_dn}"
      scope         = item.value.scope
      category      = item.value.category
      description   = item.value.description
      members       = item.value.members
      authoritative = item.value.authoritative
    }
  }
}

# More domain controllers: each joins the domain, reboots, then is promoted.
# AD DS goes on while the forest is still being made.
circuit "domain_controllers" {
  hosts = local.others

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = true
    timeout          = "15m"
  }

  step "ad_ds" {
    windows_feature {
      name                     = "AD-Domain-Services"
      include_management_tools = true
    }
  }

  # The forest root first; promotion adds loopback itself, so it's here
  # from the start.
  step "dns" {
    depends_on = [conn3x_windows_ad_ou.forest__child_ous]

    windows_dns_client {
      servers = [local.ip[local.root], "127.0.0.1"]
    }
  }

  step "join" {
    windows_domain_membership {
      domain      = var.domain_name
      username    = local.admin_user
      password_wo = var.domain_admin_password
    }
  }

  step "joined" {
    windows_reboot {
      only_if_pending = true
    }
  }

  step "dc" {
    windows_ad_domain_controller {
      domain_name           = var.domain_name
      username              = local.admin_user
      password_wo           = var.domain_admin_password
      safe_mode_password_wo = var.safe_mode_password
    }
  }

  step "promoted" {
    windows_reboot {
      only_if_pending = true
      timeout         = "15m"
    }
  }

  step "adws" {
    windows_wait_for {
      port    = 9389
      timeout = "10m"
    }
  }

  step "ad_answers" {
    windows_powershell {
      script = local.ad_answers
      unless = local.ad_answers_unless
    }
  }
}

# Member servers point their DNS at the DCs and join.
circuit "members" {
  hosts = var.members

  # On a member, the bare name stays the local account.
  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = true
    timeout          = "15m"
  }

  step "dns" {
    depends_on = [conn3x_windows_ad_ou.forest__child_ous]

    windows_dns_client {
      servers = local.dns_dcs
    }
  }

  step "join" {
    windows_domain_membership {
      domain      = var.domain_name
      ou          = local.member_ou
      username    = local.admin_user
      password_wo = var.domain_admin_password
    }
  }

  step "joined" {
    windows_reboot {
      only_if_pending = true
    }
  }
}

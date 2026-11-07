variable "domain_name" {
  type        = string
  description = "DNS name of the new forest's root domain, such as lab.example.com."

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a DNS name with at least two labels, such as lab.example.com."
  }
}

variable "netbios_name" {
  type        = string
  default     = null
  description = "NetBIOS name of the domain, up to 15 characters, such as LAB. When null, Windows takes it from the first label of domain_name."

  validation {
    condition     = var.netbios_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$", var.netbios_name))
    error_message = "netbios_name must be 1 to 15 letters, digits or -, starting with a letter or digit."
  }
}

variable "domain_controllers" {
  type        = any
  description = "Domain controllers, by name: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts and private_ip. private_ip is the address other hosts reach its DNS on, when that isn't address. The first name in sorted order makes the forest."

  validation {
    condition     = length(var.domain_controllers) > 0
    error_message = "Give at least one domain controller."
  }
}

variable "forest_root" {
  type        = string
  default     = null
  description = "Domain controller that makes the forest. When null, the first name in sorted order. Keep it the same for the life of the domain."

  validation {
    condition     = var.forest_root == null || contains(keys(var.domain_controllers), coalesce(var.forest_root, "-"))
    error_message = "forest_root must be one of the names in domain_controllers."
  }
}

variable "members" {
  type        = any
  default     = {}
  description = "Member servers to join to the domain, by name, in the same form as domain_controllers. A name can't be both."

  validation {
    condition     = length(setintersection(keys(var.domain_controllers), keys(var.members))) == 0
    error_message = "A name can't be both a domain controller and a member."
  }
}

variable "member_ou" {
  type        = string
  default     = null
  description = "OU for the members' computer accounts, relative to the domain, such as OU=Servers,OU=Lab. When null, the domain's default, CN=Computers. Used only when a member joins."
}

variable "safe_mode_password" {
  type        = string
  ephemeral   = true
  description = "Directory Services Restore Mode password for every domain controller. Never in plan or state. Used only when a DC is promoted."
}

variable "domain_admin_username" {
  type        = string
  default     = null
  description = "Domain account that joins members and promotes the other DCs, such as LAB\\azadmin. When null, the NetBIOS name and ssh_user. The forest root's admin becomes this account when the forest is made."
}

variable "domain_admin_password" {
  type        = string
  ephemeral   = true
  default     = null
  description = "Password of domain_admin_username. Never in plan or state. Needed only while a host still has to join or be promoted: once the forest is made, it's the password the forest root's admin had."
}

variable "ous" {
  type = map(object({
    path        = optional(string)
    description = optional(string)
    protected   = optional(bool)
  }))
  default     = {}
  description = "OUs, by name. path is the parent relative to the domain, such as OU=Lab; null is the top of the domain. An OU's path can name an OU from this map at the top of the domain, or one that already exists."
}

variable "users" {
  type = map(object({
    path                   = optional(string)
    upn                    = optional(string)
    given_name             = optional(string)
    surname                = optional(string)
    display_name           = optional(string)
    description            = optional(string)
    enabled                = optional(bool)
    password_never_expires = optional(bool)
  }))
  default     = {}
  description = "Users, by logon name. path is the OU relative to the domain, such as OU=Lab; null is CN=Users. upn defaults to name@domain_name. A user with a password in user_passwords is enabled unless enabled = false; one without stays disabled."
}

variable "user_passwords" {
  type        = map(string)
  ephemeral   = true
  default     = {}
  description = "Passwords for users, by logon name. Never in plan or state: state keeps an HMAC, so changing one plans a reset."
}

variable "groups" {
  type = map(object({
    path          = optional(string)
    scope         = optional(string)
    category      = optional(string)
    description   = optional(string)
    members       = optional(set(string))
    authoritative = optional(bool)
  }))
  default     = {}
  description = "Groups, by name. path as for users. members are sAMAccountNames: users from users, or accounts that already exist. scope is domainlocal, global or universal; category is security or distribution."
}

variable "ssh_user" {
  type        = string
  default     = "Administrator"
  description = "User to log in as on every host: the bare name of an administrator, such as azadmin. On the forest root it becomes the domain's account of that name."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

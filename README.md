# circuit-active-directory

A Conn3x circuit that builds an Active Directory domain from roles. One server makes a new forest, any others you list become more domain controllers, member servers join, and the directory gets the OUs, users and groups you describe. Every reboot is a step in the plan, so you see the whole build before anything changes.

**Preview.** Windows support in Conn3x is in preview. Since Conn3x v0.19.0, every module this circuit uses is out of experimental, so their arguments hold between releases. The circuit itself needs Conn3x v0.7.3 or later.

## Usage

```hcl
module "ad" {
  source = "github.com/conn3xorg/circuit-active-directory?ref=v0.1.0"

  domain_name  = "lab.example.com"
  netbios_name = "LAB"

  domain_controllers = {
    dc1 = { address = "203.0.113.10", host_key = "ssh-ed25519 AAAA...", private_ip = "10.0.0.4" }
    dc2 = { address = "203.0.113.11", host_key = "ssh-ed25519 AAAA...", private_ip = "10.0.0.5" }
  }
  members = {
    srv1 = { address = "203.0.113.12", host_key = "ssh-ed25519 AAAA..." }
  }

  ssh_user              = "azadmin"
  ssh_private_key_file  = "~/.ssh/id_ed25519"
  safe_mode_password    = var.dsrm_password  # ephemeral
  domain_admin_password = var.admin_password # ephemeral

  ous = {
    Lab     = {}
    Servers = { path = "OU=Lab" }
  }
  member_ou = "OU=Servers,OU=Lab"

  users = {
    alice = { path = "OU=Lab", given_name = "Alice", surname = "Smith" }
  }
  user_passwords = var.user_passwords # ephemeral, {alice = "..."}

  groups = {
    LabAdmins = { path = "OU=Lab", members = ["alice"] }
  }
}
```

Run `conn3x init` and `conn3x apply`. On four `Standard_B2s_v2` Azure VMs, two DCs and two members, the first apply took 15 to 18 minutes, VMs included, and a second `conn3x plan` said `No changes.` [`examples/azure-ad-lab`](https://github.com/conn3xorg/conn3x/tree/main/examples/azure-ad-lab) in the Conn3x repo builds that lab from one config.

Each host needs OpenSSH Server running and your key in `administrators_authorized_keys`, and the DCs need fixed private addresses, because the other hosts' DNS names them.

## What it does

On the forest root, the first domain controller by name unless you set `forest_root`:

1. Checks it's x86_64 Windows Server 2022 or 2025.
2. Installs AD DS with its management tools.
3. Makes the forest, with DNS, and reboots.
4. Waits for Active Directory Web Services on port 9389, then for `Get-ADDomain` and a query through the global catalog. sshd answers before AD does, and on Azure an OU made in the minute before the global catalog answered hung.
5. Points its DNS at itself, then loopback.
6. Makes the OUs in `ous`, top-level ones first, then the users in `users`, then the groups in `groups` with their members.

On each other domain controller, at the same time as the forest root as far as it can:

1. Installs AD DS while the forest is still being made.
2. Once the OUs exist, points its DNS at the forest root, then loopback.
3. Joins the domain and reboots.
4. Is promoted to a domain controller, with DNS and a global catalog, and reboots.
5. Waits for AD to answer.

On each member server, once the OUs exist:

1. Points its DNS at the domain controllers, the forest root first.
2. Joins the domain, into `member_ou` if you set it, and reboots.

## Logging in

You log in the same way before and after. With the bare name, such as `azadmin`, the forest root's admin becomes the domain's `LAB\azadmin` when the forest is made, and keeps your key. On another DC the same name is the domain's account after promotion. On a member it stays the local account. That's why `ssh_user` must be a bare name.

The forest's first admin password becomes the domain admin's. Pass it as `domain_admin_password`, and the other DCs and the members join with it. Replace it once the domain is built: [`examples/azure-ad-lab`](https://github.com/conn3xorg/conn3x/tree/main/examples/azure-ad-lab) does that as its last step.

## Passwords stay out of state

`safe_mode_password`, `domain_admin_password` and `user_passwords` are ephemeral. Conn3x sends them to the host on stdin and turns them into `SecureString` values through .NET before any cmdlet sees them. They're never in plan or state, and they're blanked from errors. For users, state keeps an HMAC, so changing a password in `user_passwords` plans a reset.

## What it doesn't do

- Child domains, trusts, sites, or read-only DCs. One forest, one domain.
- Demote a DC or take a host out of the domain. Removing a host, or the module, leaves it as it is. Delete the VM for that.
- Delete OUs, users or groups you take out of the inputs. They stay in the directory.
- Put a computer in a group on the first apply. Members of `groups` must be users from `users` or accounts that already exist.
- Nest OUs more than one level under OUs it makes itself. An OU's `path` can name a top-level OU from `ous`, or any OU that already exists.
- Put AD's database on a data disk. It stays under `C:\Windows`. For a domain you'd keep, use the forest and DC modules directly with `database_path`, `log_path` and `sysvol_path`.

## Tests

- **On Azure:** four `Standard_B2s_v2` VMs on Windows Server 2025, built from nothing three times in a row. Each time the second plan was empty, `repadmin /replsummary` showed 0 failures on both DCs, `Test-ComputerSecureChannel` was True on both members, the OUs, users, groups and computer accounts were where the inputs put them, `conn3x drift` caught a user taken out of a group by hand, and the passwords had 0 hits in Conn3x's plan and apply output, logs and state, and in the hosts' event logs and log files.
- **In CI, on the windows-2022 and windows-2025 runners:** a shared runner can't reboot or become a domain controller. So CI plans the forest root against the runner itself, which runs every read for real, installs AD DS, and checks the next plan no longer has it but still has the forest. Promotion, joins and the directory steps are only tested on Azure.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `domain_name` | string | Required | DNS name of the new forest's root domain, such as `lab.example.com`. |
| `netbios_name` | string | `null` | NetBIOS name, up to 15 characters, such as `LAB`. When null, Windows picks it from the first label. |
| `domain_controllers` | any | Required | Domain controllers, by name. Each value is an address, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA...", private_ip = "10.0.0.4" }`, which can also set `user`, `port`, `private_key_file` and `jump_hosts`. `private_ip` is the address other hosts reach its DNS on, when that isn't `address`. |
| `forest_root` | string | `null` | Domain controller that makes the forest. When null, the first name in sorted order. Keep it the same for the life of the domain. |
| `members` | any | `{}` | Member servers to join, by name, in the same form. |
| `member_ou` | string | `null` | OU for the members' computer accounts, relative to the domain, such as `OU=Servers,OU=Lab`. When null, `CN=Computers`. |
| `safe_mode_password` | string, ephemeral | Required | Directory Services Restore Mode password for every DC. Used only at promotion. |
| `domain_admin_username` | string | `null` | Domain account that joins members and promotes the other DCs. When null, the NetBIOS name and `ssh_user`, such as `LAB\azadmin`. |
| `domain_admin_password` | string, ephemeral | `null` | Its password. Needed only while a host still has to join or be promoted. |
| `ous` | map(object) | `{}` | OUs by name, each with optional `path` (the parent relative to the domain; null is the top), `description` and `protected`. |
| `users` | map(object) | `{}` | Users by logon name, each with optional `path`, `upn` (default `name@domain_name`), `given_name`, `surname`, `display_name`, `description`, `enabled` and `password_never_expires`. |
| `user_passwords` | map(string), ephemeral | `{}` | Passwords for users, by logon name. A user with one is enabled, a user without one stays disabled. |
| `groups` | map(object) | `{}` | Groups by name, each with optional `path`, `scope`, `category`, `description`, `members` (sAMAccountNames) and `authoritative`. |
| `ssh_user` | string | `"Administrator"` | The bare name of an administrator to log in as on every host. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. Not used for a host object with `host_key`. |

## Outputs

| Name | Description |
| --- | --- |
| `domain_name` | DNS name of the domain. |
| `domain_dn` | Distinguished name of the domain, such as `DC=lab,DC=example,DC=com`. |
| `forest_root` | Name of the DC that made the forest. |
| `dns_servers` | DNS servers the members use, the forest root first. |

## License

MPL-2.0. See [LICENSE](LICENSE).

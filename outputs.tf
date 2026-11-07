output "domain_name" {
  description = "DNS name of the domain."
  value       = var.domain_name
}

output "domain_dn" {
  description = "Distinguished name of the domain, such as DC=lab,DC=example,DC=com."
  value       = local.domain_dn
}

output "forest_root" {
  description = "Name of the domain controller that made the forest."
  value       = local.root
}

output "dns_servers" {
  description = "DNS servers the members use: the forest root first, then the other DCs by name."
  value       = local.dns_dcs
}

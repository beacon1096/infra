output "terraform_dns_token" {
  value     = cloudflare_account_token.terraform_dns.value
  sensitive = true
}

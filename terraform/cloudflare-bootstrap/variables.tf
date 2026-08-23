variable "cloudflare_account_id" {
  type    = string
  default = "f9234eb526c9fa8a714390b323797bb8"
}

variable "cloudflare_dns_zone_ids" {
  type = set(string)
  default = [
    "d0a22be353820d23e7addbce27a3f604",
    "00b637aa26199c8546df1bfe2131fc0f",
  ]
}

data "authentik_flow" "provider_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_certificate_key_pair" "signing" {
  name              = "authentik Self-signed Certificate"
  fetch_certificate = false
  fetch_key         = false
}

data "authentik_property_mapping_provider_scope" "oidc" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-email",
  ]
}

resource "authentik_provider_oauth2" "tailscale" {
  name      = "Tailscale @ Beacoworks"
  client_id = "tailscale"

  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.signing.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids

  client_type                = "confidential"
  issuer_mode                = "per_provider"
  sub_mode                   = "hashed_user_id"
  include_claims_in_id_token = true

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://login.tailscale.com/a/oauth_response"
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_application" "tailscale" {
  name              = "Tailscale @ Beacoworks"
  slug              = "tailscale"
  protocol_provider = authentik_provider_oauth2.tailscale.id

  lifecycle {
    prevent_destroy = true
  }
}

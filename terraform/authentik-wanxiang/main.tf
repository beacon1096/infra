data "authentik_flow" "provider_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "provider_authorization_explicit" {
  slug = "default-provider-authorization-explicit-consent"
}

data "authentik_flow" "provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_flow" "authentication" {
  slug = "default-authentication-flow"
}

data "authentik_flow" "invalidation" {
  slug = "default-invalidation-flow"
}

data "authentik_certificate_key_pair" "signing" {
  name              = "authentik Self-signed Certificate"
  fetch_certificate = false
  fetch_key         = false
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "offline_access" {
  managed = "goauthentik.io/providers/oauth2/scope-offline_access"
}

data "authentik_property_mapping_provider_saml" "upn" {
  managed = "goauthentik.io/providers/saml/upn"
}

data "authentik_property_mapping_provider_saml" "name" {
  managed = "goauthentik.io/providers/saml/name"
}

data "authentik_property_mapping_provider_saml" "email" {
  managed = "goauthentik.io/providers/saml/email"
}

data "authentik_property_mapping_provider_saml" "username" {
  managed = "goauthentik.io/providers/saml/username"
}

data "authentik_property_mapping_provider_saml" "uid" {
  managed = "goauthentik.io/providers/saml/uid"
}

data "authentik_property_mapping_provider_saml" "groups" {
  managed = "goauthentik.io/providers/saml/groups"
}

data "authentik_property_mapping_provider_saml" "windows_account_name" {
  managed = "goauthentik.io/providers/saml/ms-windowsaccountname"
}

locals {
  oidc_property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
  oidc_property_mappings_with_offline_access = concat(local.oidc_property_mappings, [
    data.authentik_property_mapping_provider_scope.offline_access.id,
  ])
  saml_property_mappings = [
    data.authentik_property_mapping_provider_saml.upn.id,
    data.authentik_property_mapping_provider_saml.name.id,
    data.authentik_property_mapping_provider_saml.email.id,
    data.authentik_property_mapping_provider_saml.username.id,
    data.authentik_property_mapping_provider_saml.uid.id,
    data.authentik_property_mapping_provider_saml.groups.id,
    data.authentik_property_mapping_provider_saml.windows_account_name.id,
  ]
}

resource "authentik_provider_oauth2" "tailscale" {
  name      = "Tailscale @ Beacoworks"
  client_id = "tailscale"

  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.signing.id
  property_mappings = [
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

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

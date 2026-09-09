locals {
  outpost_config = {
    authentik_host                   = "https://id.beaco.works/"
    authentik_host_insecure          = false
    authentik_host_browser           = ""
    log_level                        = "info"
    object_naming_template           = "ak-outpost-%(name)s"
    refresh_interval                 = "minutes=5"
    container_image                  = null
    docker_network                   = null
    docker_map_ports                 = true
    docker_labels                    = null
    kubernetes_replicas              = 1
    kubernetes_namespace             = "identity"
    kubernetes_ingress_annotations   = {}
    kubernetes_ingress_secret_name   = "authentik-outpost-tls"
    kubernetes_ingress_class_name    = null
    kubernetes_ingress_path_type     = null
    kubernetes_httproute_annotations = {}
    kubernetes_httproute_parent_refs = []
    kubernetes_service_type          = "ClusterIP"
    kubernetes_disabled_components   = []
    kubernetes_image_pull_secrets    = []
    kubernetes_json_patches          = null
  }

  oidc_applications = {
    coder = {
      name             = "Coder @ Beacoworks"
      client_id        = "UTmld9ql2WdC6vWV5yJydFVMFdY6mCSYmx6tGt88"
      explicit_consent = true
      offline_access   = true
      redirect_uris = [
        {
          matching_mode = "strict"
          url           = "https://coder.beacoworks.xyz/api/v2/users/oidc/callback"
        },
        {
          matching_mode = "strict"
          url           = "https://code.beaco.works/api/v2/users/oidc/callback"
        },
      ]
    }
    forgejo = {
      name             = "Forgejo @ Beacoworks"
      client_id        = "mtZA3dhlvsdWyxaRExWeOpthkT0ZhDaNSv1U30za"
      explicit_consent = false
      offline_access   = true
      redirect_uris = [
        {
          matching_mode = "strict"
          url           = "https://forgejo.beaco.works/user/oauth2/authentik/callback"
        },
      ]
    }
    matrix = {
      name             = "Matrix @ Beacoworks"
      client_id        = "A1zaJfZZBJYjVv3H83hUWSvC8ujajOl6EKYo"
      explicit_consent = false
      offline_access   = true
      redirect_uris = [
        {
          matching_mode = "regex"
          url           = ".*"
        },
      ]
    }
    outline = {
      name             = "Outline @ Beacoworks"
      client_id        = "qTPz2aopLE5BxWqo2aCUHGxECBFsnst2hyrQVtTW"
      explicit_consent = false
      offline_access   = false
      redirect_uris = [
        {
          matching_mode = "regex"
          url           = "https://docs.beacoworks.xyz/auth/oidc.callback"
        },
      ]
    }
    vaultwarden = {
      name             = "Vault @ Beacoworks"
      client_id        = "gldPsiyalUj7wT6n9ujj6b0rDnfTQFP9MUGWPgUU"
      explicit_consent = false
      offline_access   = true
      redirect_uris = [
        {
          matching_mode = "strict"
          url           = "https://vault.beaco.works/identity/connect/oidc-signin"
        },
      ]
    }
  }
}

resource "authentik_provider_oauth2" "oidc" {
  for_each = local.oidc_applications

  name      = each.value.name
  client_id = each.value.client_id

  authorization_flow = each.value.explicit_consent ? data.authentik_flow.provider_authorization_explicit.id : data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.signing.id
  property_mappings  = each.value.offline_access ? local.oidc_property_mappings_with_offline_access : local.oidc_property_mappings

  access_token_validity      = "minutes=5"
  allowed_redirect_uris      = each.value.redirect_uris
  client_type                = "confidential"
  issuer_mode                = "per_provider"
  sub_mode                   = "hashed_user_id"
  include_claims_in_id_token = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_application" "oidc" {
  for_each = local.oidc_applications

  name              = each.value.name
  slug              = each.key
  protocol_provider = authentik_provider_oauth2.oidc[each.key].id

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_provider_saml" "n8n" {
  name = "Automation @ Beacoworks"

  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  property_mappings  = local.saml_property_mappings

  acs_url = "https://automaton.beaco.works/saml"

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_application" "n8n" {
  name              = "Automation @ Beacoworks"
  slug              = "n8n"
  protocol_provider = authentik_provider_saml.n8n.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_provider_radius" "netlock" {
  name = "Radius @ Beacoworks"

  authorization_flow = data.authentik_flow.authentication.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  shared_secret      = var.netlock_radius_shared_secret

  client_networks = "172.16.0.0/16, ::/0"
  mfa_support     = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_application" "netlock" {
  name              = "NetLock @ Beacoworks"
  slug              = "netlock"
  protocol_provider = authentik_provider_radius.netlock.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_outpost" "radius" {
  name               = "Radius"
  type               = "radius"
  protocol_providers = [authentik_provider_radius.netlock.id]
  service_connection = "b6403a21-4113-435c-ace9-cd3148ff9a31"
  config             = jsonencode(local.outpost_config)

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_provider_rac" "anyconn" {
  name = "AnyConn @ Beacoworks"

  authorization_flow = data.authentik_flow.provider_authorization.id
  connection_expiry  = "hours=8"
  settings           = var.anyconn_rac_settings

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_application" "anyconn" {
  name              = "AnyConn @ Beacoworks"
  slug              = "anyconn--beacoworks"
  protocol_provider = authentik_provider_rac.anyconn.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_outpost" "rac" {
  name               = "RAC"
  type               = "rac"
  protocol_providers = [authentik_provider_rac.anyconn.id]
  service_connection = "b6403a21-4113-435c-ace9-cd3148ff9a31"
  config             = jsonencode(local.outpost_config)

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_property_mapping_provider_rac" "rdp_beaco" {
  name     = "RDP beaco"
  settings = var.rac_rdp_beaco_settings

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_property_mapping_provider_rac" "rdp_beacon" {
  name     = "RDP: beacon"
  settings = var.rac_rdp_beacon_settings

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_rac_endpoint" "lab_secret" {
  name              = "Lab-01: Secret"
  host              = "172.16.20.51"
  protocol          = "rdp"
  protocol_provider = authentik_provider_rac.anyconn.id
  property_mappings = [authentik_property_mapping_provider_rac.rdp_beaco.id]

  maximum_connections = -1

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_rac_endpoint" "wishlist" {
  name              = "Wishlist"
  host              = "172.16.101.137:2222"
  protocol          = "ssh"
  protocol_provider = authentik_provider_rac.anyconn.id

  maximum_connections = -1

  lifecycle {
    prevent_destroy = true
  }
}

resource "authentik_rac_endpoint" "kso_vm" {
  name              = "kso-vm"
  host              = "172.16.101.20"
  protocol          = "rdp"
  protocol_provider = authentik_provider_rac.anyconn.id
  property_mappings = [authentik_property_mapping_provider_rac.rdp_beacon.id]

  maximum_connections = 1

  lifecycle {
    prevent_destroy = true
  }
}

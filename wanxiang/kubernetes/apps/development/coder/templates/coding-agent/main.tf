terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace" {
  type    = string
  default = "development"
}

variable "image" {
  type = string
  # Published by CI to the Forgejo registry, not the plain-HTTP zot LB:
  # cluster nodes reach forgejo.beaco.works over envoy-internal with a real
  # cert (machineconfig extraHostEntries), whereas 172.16.87.51:5000 is only
  # reachable via a mirror that Spegel shadows, so zot-only images fail to
  # pull. See the coding-agent-oci image in the NixOS flake.
  default = "forgejo.beaco.works/infrastructure/nix-fleet/coding-agent@sha256:e4c5c686f898511fc72a1575ab156c2b7cd9f67ebf691418d74a3327e6eecd53"
}

variable "home_disk_size" {
  type    = string
  default = "50Gi"
}

variable "agent_secret_name" {
  type    = string
  default = "coder-workspace-agent"
}

variable "git_ssh_secret_name" {
  type    = string
  default = "coder-workspace-git-ssh"
}

variable "infra_secret_name" {
  type    = string
  default = "coder-workspace-infra"
}

variable "cpu_request" {
  type    = string
  default = "500m"
}

variable "memory_request" {
  type    = string
  default = "2Gi"
}

variable "memory_limit" {
  type    = string
  default = "8Gi"
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

locals {
  workspace_slug         = lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-"))
  owner_slug             = lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-"))
  app                    = "coder-${local.owner_slug}-${local.workspace_slug}"
  copilot_workspace      = data.coder_workspace_owner.me.name == "beacon1096" && data.coder_workspace.me.name == "infra-maintainer"
  gitops_workspace       = data.coder_workspace_owner.me.name == "beacon1096" && data.coder_workspace.me.name == "gitops-agent"
  nix_packager_workspace = data.coder_workspace_owner.me.name == "beacon1096" && data.coder_workspace.me.name == "nix-packager-agent"
  legacy_workspace       = data.coder_workspace_owner.me.name == "beacon1096" && data.coder_workspace.me.name == "nixos-agent-coder"
  agent_secret           = local.gitops_workspace ? "coder-workspace-gitops-agent" : local.nix_packager_workspace ? "coder-workspace-nix-packager-agent" : local.legacy_workspace ? var.agent_secret_name : ""
  git_ssh_secret         = local.gitops_workspace ? "coder-workspace-gitops-git-ssh" : local.nix_packager_workspace ? "coder-workspace-nix-packager-git-ssh" : local.legacy_workspace ? var.git_ssh_secret_name : ""
  infra_secret           = local.gitops_workspace || local.legacy_workspace ? var.infra_secret_name : ""
  git_identity_workspace = local.copilot_workspace || local.gitops_workspace || local.nix_packager_workspace
  git_user_name          = local.copilot_workspace ? "beacon1096" : local.nix_packager_workspace ? "Nix 打包维护者 @ Beacoworks" : "GitOps + 运维 @ Beacoworks"
  git_user_email         = local.copilot_workspace ? "beacon1096@beacoworks.xyz" : local.nix_packager_workspace ? "multica-nix-packager.no-reply@beacoworks.xyz" : "multica-gitops.no-reply@beacoworks.xyz"
  git_signing_key        = local.copilot_workspace ? "/home/coder/.ssh/beacon1096-copilot/id_ed25519" : local.nix_packager_workspace ? "8F57D2F99F73669B937CC52E93BF0D5DA19E76C2" : "B2FAAFEAC5E4727FB4AF35784932794C9ED791BE"
}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"
  dir  = "/home/coder/workspace"

  env = merge({
    CODER_WORKSPACE_DIR = "/home/coder/workspace"
    GIT_CONFIG_COUNT    = local.git_identity_workspace ? "5" : "1"
    GIT_CONFIG_KEY_0    = "user.signingKey"
    GIT_CONFIG_VALUE_0  = local.git_identity_workspace ? local.git_signing_key : "/home/coder/.ssh/runtime/id_ed25519"
    GIT_CONFIG_KEY_1    = "user.name"
    GIT_CONFIG_VALUE_1  = local.git_user_name
    GIT_CONFIG_KEY_2    = "user.email"
    GIT_CONFIG_VALUE_2  = local.git_user_email
    GIT_CONFIG_KEY_3    = "commit.gpgsign"
    GIT_CONFIG_VALUE_3  = "true"
    GIT_CONFIG_KEY_4    = "gpg.format"
    GIT_CONFIG_VALUE_4  = local.gitops_workspace || local.nix_packager_workspace ? "openpgp" : "ssh"
    GIT_SSH_COMMAND     = "ssh -F /home/coder/.ssh/config -i ${local.copilot_workspace ? "/home/coder/.ssh/beacon1096-copilot/id_ed25519" : "/home/coder/.ssh/runtime/id_ed25519"} -o UserKnownHostsFile=/home/coder/.ssh/known_hosts -o StrictHostKeyChecking=yes"
    }, local.infra_secret == "" ? {} : {
    KUBECONFIG        = "/run/coder-infra/kubeconfig"
    SOPS_AGE_KEY_FILE = "/run/coder-infra/sops-age-keys"
    TALOSCONFIG       = "/run/coder-infra/talosconfig"
  })

  startup_script = <<-EOT
    set -e
    mkdir -p /home/coder/workspace

    install_secret() {
      source="/run/coder-agent-secrets/$1"
      target="$2"
      if [ -f "$source" ]; then
        install -D -m 0600 "$source" "$target"
      fi
    }

    install_secret CLAUDE_CREDENTIALS_JSON /home/coder/.claude/.credentials.json
    install_secret CODEX_AUTH_JSON /home/coder/.codex/auth.json
    install_secret OPENCODE_AUTH_JSON /home/coder/.local/share/opencode/auth.json
    if [ ! -f /home/coder/.multica/config.json ]; then
      install_secret MULTICA_CONFIG_JSON /home/coder/.multica/config.json
    fi
    install_secret GH_HOSTS_YML /home/coder/.config/gh/hosts.yml
    if [ -f /run/coder-agent-secrets/FORGEJO_GIT_CREDENTIALS ]; then
      install_secret FORGEJO_GIT_CREDENTIALS /home/coder/.config/git/credentials
      git config --global credential.https://forgejo.beaco.works.helper 'store --file /home/coder/.config/git/credentials'
    fi
    if [ "${local.copilot_workspace}" = "true" ]; then
      git config --file /home/coder/.gitconfig user.name beacon1096
      git config --file /home/coder/.gitconfig user.email beacon1096@beacoworks.xyz
      git config --file /home/coder/.gitconfig user.signingKey /home/coder/.ssh/beacon1096-copilot/id_ed25519
      git config --file /home/coder/.gitconfig gpg.format ssh
      git config --file /home/coder/.gitconfig commit.gpgsign true
      git config --file /home/coder/.gitconfig core.sshCommand 'ssh -F /home/coder/.ssh/config -i /home/coder/.ssh/beacon1096-copilot/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/coder/.ssh/known_hosts -o StrictHostKeyChecking=yes'
      chmod 0600 /home/coder/.gitconfig
    fi
    if [ -s /run/coder-agent-secrets/FORGEJO_API_TOKEN ] && command -v tea >/dev/null 2>&1; then
      tea login delete forgejo >/dev/null 2>&1 || true
      if ! GITEA_SERVER_TOKEN="$(cat /run/coder-agent-secrets/FORGEJO_API_TOKEN)" \
        tea login add --name forgejo --url https://forgejo.beaco.works --no-version-check; then
        echo "tea Forgejo login failed" >&2
      fi
    fi

    if [ -f /run/coder-git-ssh/id_ed25519 ]; then
      install -d -m 0700 /home/coder/.ssh/runtime
      install -m 0600 /run/coder-git-ssh/id_ed25519 /home/coder/.ssh/runtime/id_ed25519
      if [ -f /run/coder-git-ssh/id_ed25519.pub ]; then
        install -m 0644 /run/coder-git-ssh/id_ed25519.pub /home/coder/.ssh/runtime/id_ed25519.pub
      else
        ssh-keygen -y -f /home/coder/.ssh/runtime/id_ed25519 > /home/coder/.ssh/runtime/id_ed25519.pub
        chmod 0644 /home/coder/.ssh/runtime/id_ed25519.pub
      fi
    fi

    if [ -f /run/coder-agent-secrets/GPG_SIGNING_KEY ]; then
      install -d -m 0700 /home/coder/.gnupg
      gpg --batch --import /run/coder-agent-secrets/GPG_SIGNING_KEY
    fi

    if [ "${local.git_identity_workspace}" = "true" ]; then
      git config --global user.name '${local.git_user_name}'
      git config --global user.email '${local.git_user_email}'
      git config --global user.signingkey '${local.git_signing_key}'
      git config --global gpg.format openpgp
      git config --global commit.gpgsign true
    fi

    if [ -S /tmp/tailscale/tailscaled.sock ]; then
      tailscale --socket=/tmp/tailscale/tailscaled.sock set --accept-routes=true
    fi

    if [ -f /home/coder/.multica/config.json ] && command -v multica >/dev/null 2>&1; then
      multica daemon start || multica daemon status >/dev/null
    fi
  EOT
}

resource "coder_app" "opencode" {
  agent_id     = coder_agent.main.id
  slug         = "opencode"
  display_name = "OpenCode"
  url          = "http://localhost:4096"
  share        = "owner"
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "${local.app}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "coder-workspace"
      "app.kubernetes.io/instance"   = local.app
      "coder.com/workspace-id"       = data.coder_workspace.me.id
      "coder.com/workspace-owner-id" = data.coder_workspace_owner.me.id
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.home_disk_size
      }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_pod" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.app
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "coder-workspace"
      "app.kubernetes.io/instance"   = local.app
      "coder.com/workspace-id"       = data.coder_workspace.me.id
      "coder.com/workspace-owner-id" = data.coder_workspace_owner.me.id
    }
  }

  spec {
    restart_policy = "Always"

    container {
      name              = "dev"
      image             = var.image
      image_pull_policy = "Always"
      args              = ["/bin/coder-agent", "agent"]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_AGENT_AUTH"
        value = "token"
      }

      env {
        name  = "CODER_AGENT_URL"
        value = "https://code.beaco.works/"
      }

      env {
        name  = "CODER_WORKSPACE_DIR"
        value = "/home/coder/workspace"
      }

      env {
        name  = "TS_HOSTNAME"
        value = local.app
      }

      dynamic "env" {
        for_each = local.infra_secret == "" ? {} : {
          KUBECONFIG        = "/run/coder-infra/kubeconfig"
          SOPS_AGE_KEY_FILE = "/run/coder-infra/sops-age-keys"
          TALOSCONFIG       = "/run/coder-infra/talosconfig"
        }
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.agent_secret == "" ? [] : [local.agent_secret]
        content {
          name = "TS_AUTHKEY"
          value_from {
            secret_key_ref {
              name     = env.value
              key      = "TS_AUTHKEY"
              optional = true
            }
          }
        }
      }

      env {
        name  = "BEACOWORKS_MODELS_API_BASE"
        value = "http://litellm.ai.svc.cluster.local:4000/v1"
      }

      dynamic "env" {
        for_each = local.agent_secret == "" ? [] : [
          "BEACOWORKS_MODELS_API_KEY",
          "TAVILY_API_KEY",
        ]
        content {
          name = env.value
          value_from {
            secret_key_ref {
              name = local.agent_secret
              key  = env.value
            }
          }
        }
      }

      resources {
        requests = {
          cpu    = var.cpu_request
          memory = var.memory_request
        }
        limits = {
          memory = var.memory_limit
        }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }

      volume_mount {
        name       = "ssh-home"
        mount_path = "/home/coder/.ssh/runtime"
      }

      dynamic "volume_mount" {
        for_each = local.git_ssh_secret == "" ? [] : [local.git_ssh_secret]
        content {
          name       = "git-ssh-secret"
          mount_path = "/run/coder-git-ssh"
          read_only  = true
        }
      }

      dynamic "volume_mount" {
        for_each = local.agent_secret == "" ? [] : [local.agent_secret]
        content {
          name       = "agent-secrets"
          mount_path = "/run/coder-agent-secrets"
          read_only  = true
        }
      }

      dynamic "volume_mount" {
        for_each = local.infra_secret == "" ? [] : [local.infra_secret]
        content {
          name       = "infra-secrets"
          mount_path = "/run/coder-infra"
          read_only  = true
        }
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }

    volume {
      name = "ssh-home"
      empty_dir {}
    }

    dynamic "volume" {
      for_each = local.git_ssh_secret == "" ? [] : [local.git_ssh_secret]
      content {
        name = "git-ssh-secret"
        secret {
          secret_name = volume.value
        }
      }
    }

    dynamic "volume" {
      for_each = local.agent_secret == "" ? [] : [local.agent_secret]
      content {
        name = "agent-secrets"
        secret {
          secret_name = volume.value
        }
      }
    }

    dynamic "volume" {
      for_each = local.infra_secret == "" ? [] : [local.infra_secret]
      content {
        name = "infra-secrets"
        secret {
          secret_name = volume.value
        }
      }
    }
  }
}

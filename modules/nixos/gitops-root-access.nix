# GitOps + 运维 runtime root access.
#
# Grants the shared GitOps runtime key root SSH on managed infrastructure.
# The key comment is the identity; a single key represents that runtime
# (see docs/agentic/permissions/README.md). Import only in infrastructure
# hosts — never in daily-use personal devices.
{ ... }:

{
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBwxZlOGdS5wy5dWPvAaI7d0dXt9+aGz+p8XTzZG+y6Q multica-gitops-push"
  ];
}

# rules/

Shared agent instructions, version-controlled with the flake.

`AGENTS.md` here is the single source. Home Manager wires it into each
agent CLI via the tool's `context` option — see `modules/home/coding.nix`.

To edit: change `AGENTS.md` here, then `nixos-rebuild switch`. The targets
in the home directory are read-only symlinks into the Nix store; do not
edit them directly.

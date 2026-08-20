# Global Agent Rules

Shared instructions for Claude Code, Codex CLI, and OpenCode. Single source at
`/etc/nixos/rules/AGENTS.md`, wired through each tool's HM `context` option to
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`
(read-only Nix-store symlinks). Edit here, rebuild, all three update.

## Environment

You are running on a Nix-managed system — either **NixOS** (flake at
`/etc/nixos`) or **nix-darwin** (flake at `/home/beacon/.config/nix-darwin`).

- Packages, services, and shell config are declarative; don't mutate them at
  runtime. If you need a tool that's missing, get it ad-hoc with
  `nix-shell -p <pkg>` or `nix run nixpkgs#<pkg>` — do not edit the flake to
  add a one-off dependency unless the user asks.
- `/bin` and `/usr/bin` are FUSE-backed (NixOS `services.envfs`), so
  hard-coded `#!/bin/bash` / `#!/usr/bin/env python3` scripts resolve normally.

## Style

- Be terse. No throat-clearing, no "Great question!", no end-of-turn summaries
  unless asked.
- Default to no comments in code. Only annotate non-obvious WHY (hidden
  invariants, workarounds for specific upstream bugs).
- Prefer editing existing files over creating new ones. Don't add
  documentation files unless asked.

## Repository Providers

- Inspect `git remote` before selecting provider-specific skills or tools.
- For Forgejo remotes, do not use or cite GitHub plugin skills, including
  `github:github`, `github:yeet`, `github:gh-fix-ci`, and
  `github:gh-address-comments`.
- Use ordinary `git` commands and Forgejo-native workflows for Forgejo
  repositories.

## Delegation

When a task will generate a large volume of intermediate context that you
don't need to retain in the main conversation — running `/specify` /
`/plan` / `/tasks` (spec-kit), broad codebase surveys, multi-file refactor
plans, security audits, anything that produces a wall of tool output before
the answer — **delegate it to a subagent.** You receive only the subagent's
final summary, keeping your own context window focused on the user's
overall goal.

Do **not** execute these end-to-end yourself: the intermediate steps
(spec drafts, scratch files, repeated greps) crowd out the global picture
and reduce the quality of subsequent decisions.

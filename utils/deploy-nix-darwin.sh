#!/usr/bin/env bash
#
# Deploy or update nix-darwin on a remote macOS machine.
# Idempotent — safe to run repeatedly for config updates.
#
# Flow:
#   [1/6] SSH login (pubkey or password, multiplexed for the rest)
#   [2/6] Upload local nix-darwin config via rsync
#   [3/6] Install Homebrew (skipped if present)
#   [4/6] Install Nix daemon (skipped if present)
#   [5/6] Apply nix-darwin config:
#         --local-build: build locally → nix copy closure → activate on remote
#         default:       build + activate on remote (darwin-rebuild or bootstrap)
#   [6/6] Extract age public key from SSH host key

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  utils/deploy-nix-darwin.sh --host <ssh-host> --flake-host <name> [options]

Required:
  --host <ssh-host>              SSH host or IP of target macOS machine
  --flake-host <name>            Host key in flake output, e.g. beacon-mac-mini-m4 / clerk

Options:
  --user <ssh-user>              SSH user (default: current local user)
  --port <ssh-port>              SSH port (default: 22)
  --remote-dir <path>            Destination directory on target (default: ~/nixconf-darwin)
  --source-dir <path>            Local source directory to upload (default: repo root)
  --proxy <url>                  HTTP(S) proxy for remote downloads (e.g. http://192.168.1.1:7890)
  --cn                           Use Chinese mirrors for Nix install and substituters
  --local-build                  Build locally, push closure to remote, activate there
  --no-strict-host-key-check     Disable strict host key checking on first connect
  -h, --help                     Show help

Examples:
  utils/deploy-nix-darwin.sh \
    --host 192.168.1.20 \
    --user beacon \
    --flake-host beacon-mac-mini-m4

  utils/deploy-nix-darwin.sh \
    --host clerk.local \
    --user openclaw \
    --flake-host clerk \
    --proxy http://192.168.1.1:7890 \
    --no-strict-host-key-check
EOF
}

# ── Helpers ──────────────────────────────────────────────────────────

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: command not found: $1" >&2
    exit 1
  fi
}

# Source nix-daemon.sh on the remote so nix/darwin-rebuild are in PATH.
# Embedded literally in every remote ssh heredoc that needs nix.
NIX_SOURCE='
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
'

# ── Argument parsing ────────────────────────────────────────────────

SSH_HOST=""
FLAKE_HOST=""
SSH_USER="${USER}"
SSH_PORT="22"
REMOTE_DIR=".config/nix-darwin"
# Default source dir: repo root (parent of utils/)
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STRICT_HOST_KEY_CHECKING="no"
PROXY_URL=""
USE_CN_MIRROR=false
LOCAL_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)              SSH_HOST="$2";                shift 2 ;;
    --flake-host)        FLAKE_HOST="$2";              shift 2 ;;
    --user)              SSH_USER="$2";                shift 2 ;;
    --port)              SSH_PORT="$2";                shift 2 ;;
    --remote-dir)        REMOTE_DIR="$2";              shift 2 ;;
    --source-dir)        SOURCE_DIR="$2";              shift 2 ;;
    --proxy)             PROXY_URL="$2";               shift 2 ;;
    --cn)                USE_CN_MIRROR=true;            shift ;;
    --local-build)       LOCAL_BUILD=true;              shift ;;
    --no-strict-host-key-check) STRICT_HOST_KEY_CHECKING="no"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SSH_HOST" || -z "$FLAKE_HOST" ]]; then
  echo "Error: --host and --flake-host are required." >&2
  usage
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

if [[ ! -f "$SOURCE_DIR/flake.nix" ]]; then
  echo "Error: source directory does not contain flake.nix: $SOURCE_DIR" >&2
  exit 1
fi

require_cmd ssh
require_cmd rsync

REMOTE="${SSH_USER}@${SSH_HOST}"

# Build proxy environment preamble for remote commands
# Exported so subprocesses (curl, nix, darwin-rebuild) inherit the proxy.
PROXY_ENV=""
if [[ -n "$PROXY_URL" ]]; then
  PROXY_ENV="export http_proxy='${PROXY_URL}' https_proxy='${PROXY_URL}' ALL_PROXY='${PROXY_URL}';"
fi

# Chinese mirror settings
NIX_INSTALL_URL="https://nixos.org/nix/install"
NIX_SUBSTITUTERS=""
if [[ "$USE_CN_MIRROR" == true ]]; then
  NIX_INSTALL_URL="https://mirrors.tuna.tsinghua.edu.cn/nix/latest/install"
  # CN mirrors first, official cache as fallback
  NIX_SUBSTITUTERS="https://mirror.sjtu.edu.cn/nix-channels/store https://mirrors.ustc.edu.cn/nix-channels/store https://cache.nixos.org"
fi
# Use /tmp (not $TMPDIR) — macOS $TMPDIR is too long for Unix domain sockets (104 byte limit)
CONTROL_PATH="/tmp/ndc-${SSH_USER}-${SSH_HOST}-${SSH_PORT}"

COMMON_SSH_OPTS=(
  -p "$SSH_PORT"
  -o "ControlMaster=auto"
  -o "ControlPath=$CONTROL_PATH"
  -o "ControlPersist=600"
  -o "ServerAliveInterval=30"
  -o "ServerAliveCountMax=6"
  -o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING"
)

cleanup() {
  ssh "${COMMON_SSH_OPTS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Pre-build the flake ref string so it's expanded locally, not on remote
FLAKE_REF="${REMOTE_DIR}#${FLAKE_HOST}"

# ── Step 1: SSH login ───────────────────────────────────────────────
# Establish SSH ControlMaster connection. Tries pubkey first, falls
# back to password — works for both first deploy and subsequent updates.

echo "[1/6] Connecting to ${REMOTE}..."
ssh "${COMMON_SSH_OPTS[@]}" \
  "$REMOTE" "echo 'SSH connection established.'"

# ── Step 2: Upload config ──────────────────────────────────────────

echo "[2/6] Uploading nix-darwin config from: $SOURCE_DIR"
rsync -az --delete \
  --exclude='.git' \
  --exclude='.direnv' \
  --exclude='.legacy' \
  --exclude='result' \
  --exclude='result-*' \
  -e "ssh ${COMMON_SSH_OPTS[*]}" \
  "$SOURCE_DIR/" "$REMOTE:$REMOTE_DIR/"

# ── Step 3: Install Homebrew ────────────────────────────────────────
# NOTE: Steps 3-5 pass scripts as ssh command arguments (not heredoc stdin)
# so that -t can allocate a PTY for sudo password prompts without garbling.

echo "[3/6] Checking Homebrew..."
ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" ${PROXY_ENV:+"$PROXY_ENV"} '
set -euo pipefail
if [[ -x /opt/homebrew/bin/brew ]] || [[ -x /usr/local/bin/brew ]]; then
  echo "Homebrew already installed, skipping."
  exit 0
fi
echo "Installing Homebrew..."
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
if [[ -x /opt/homebrew/bin/brew ]]; then
  # Persist brew in PATH for future login shells
  echo >> "$HOME/.zprofile"
  echo "eval \"\$(/opt/homebrew/bin/brew shellenv zsh)\"" >> "$HOME/.zprofile"
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  echo >> "$HOME/.zprofile"
  echo "eval \"\$(/usr/local/bin/brew shellenv zsh)\"" >> "$HOME/.zprofile"
  eval "$(/usr/local/bin/brew shellenv)"
fi
echo "Homebrew installed."
'

# ── Step 4: Install Nix ────────────────────────────────────────────

echo "[4/6] Checking Nix..."
ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" ${PROXY_ENV:+"$PROXY_ENV"} "NIX_INSTALL_URL='${NIX_INSTALL_URL}'" '
set -euo pipefail
if [[ -x /nix/var/nix/profiles/default/bin/nix ]] || command -v nix >/dev/null 2>&1; then
  echo "Nix already installed, skipping."
  exit 0
fi
echo "Installing Nix (multi-user daemon mode)..."
echo "  Installer: $NIX_INSTALL_URL"
curl -fsSL "$NIX_INSTALL_URL" | sh -s -- --daemon
echo "Nix installed. A new shell session may be needed for PATH changes."
'

# ── Step 5: Apply nix-darwin config ────────────────────────────────

if [[ "$LOCAL_BUILD" == true ]]; then
  # ── Local build mode ──
  # Build the system derivation locally, push the closure to the remote
  # Nix store via SSH, then activate on the remote.  All heavy lifting
  # (evaluation, fetching, building) happens on the local machine.

  LOCAL_FLAKE_REF="${SOURCE_DIR}#darwinConfigurations.${FLAKE_HOST}.system"

  echo "[5/6] Building locally: .#darwinConfigurations.${FLAKE_HOST}.system"
  if [[ -n "$NIX_SUBSTITUTERS" ]]; then
    nix build "$LOCAL_FLAKE_REF" \
      --option substituters "$NIX_SUBSTITUTERS"
  else
    nix build "$LOCAL_FLAKE_REF"
  fi

  SYSTEM_PATH="$(readlink result)"
  echo "  Built: $SYSTEM_PATH"

  echo "  Copying closure to ${REMOTE}..."
  # The remote nix-daemon rejects unsigned paths unless the SSH user is in
  # trusted-users.  Temporarily add the deploy user so nix copy works.
  # After activation, nix-darwin regenerates nix.conf and this is cleaned up.
  ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" "\
    sudo bash -c 'echo \"extra-trusted-users = ${SSH_USER}\" >> /etc/nix/nix.conf' && \
    sudo launchctl kickstart -kp system/org.nixos.nix-daemon && \
    sleep 1"

  # remote-program: nix-daemon is not in PATH on macOS non-login SSH shells
  NIX_SSHOPTS="${COMMON_SSH_OPTS[*]}" \
    nix copy --no-check-sigs \
    --to "ssh-ng://${REMOTE}?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" \
    "$SYSTEM_PATH"

  echo "  Activating on ${REMOTE}..."
  # On first deploy, nix-darwin needs to manage /etc files that the Nix
  # installer already modified.  Rename them so activation can proceed.
  ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" '\
    for f in /etc/bashrc /etc/zshrc /etc/nix/nix.conf; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        echo "  Moving $f → $f.before-nix-darwin"
        sudo mv "$f" "$f.before-nix-darwin"
      fi
    done'

  ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" "\
    sudo /nix/var/nix/profiles/default/bin/nix-env -p /nix/var/nix/profiles/system --set '${SYSTEM_PATH}' && \
    sudo '${SYSTEM_PATH}/activate'"

else
  # ── Remote build mode (default) ──
  # Build and activate on the remote machine using darwin-rebuild.

  echo "[5/6] Applying nix-darwin config: ${FLAKE_REF}"

  # On first deploy, nix-darwin needs to manage /etc files that the Nix
  # installer already modified.  Rename them so activation can proceed.
  ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" '\
    for f in /etc/bashrc /etc/zshrc /etc/nix/nix.conf; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        echo "  Moving $f → $f.before-nix-darwin"
        sudo mv "$f" "$f.before-nix-darwin"
      fi
    done'

  ssh -t "${COMMON_SSH_OPTS[@]}" "$REMOTE" ${PROXY_ENV:+"$PROXY_ENV"} "FLAKE_REF='${FLAKE_REF}'" "NIX_SUBSTITUTERS='${NIX_SUBSTITUTERS}'" '
set -euo pipefail

# Forward proxy env vars through sudo (sudo resets environment by default)
if [ -n "${http_proxy:-}" ]; then
  run_sudo() { sudo env "http_proxy=$http_proxy" "https_proxy=$https_proxy" "ALL_PROXY=$ALL_PROXY" "$@"; }
else
  run_sudo() { sudo "$@"; }
fi

# Source nix so nix/darwin-rebuild are in PATH
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

if command -v darwin-rebuild >/dev/null 2>&1; then
  echo "Running darwin-rebuild switch..."
  if [ -n "$NIX_SUBSTITUTERS" ]; then
    run_sudo darwin-rebuild switch --flake "$FLAKE_REF" \
      --option substituters "$NIX_SUBSTITUTERS"
  else
    run_sudo darwin-rebuild switch --flake "$FLAKE_REF"
  fi
else
  echo "Bootstrapping nix-darwin (first run)..."
  if [ -n "$NIX_SUBSTITUTERS" ]; then
    run_sudo nix --extra-experimental-features "nix-command flakes" \
      --option substituters "$NIX_SUBSTITUTERS" \
      run nix-darwin/master#darwin-rebuild -- switch --flake "$FLAKE_REF" \
      --option substituters "$NIX_SUBSTITUTERS"
  else
    run_sudo nix --extra-experimental-features "nix-command flakes" \
      run nix-darwin/master#darwin-rebuild -- switch --flake "$FLAKE_REF"
  fi
fi
'

fi

# ── Step 6: Extract age public key ─────────────────────────────────

echo "[6/6] Extracting age public key from SSH host key..."
AGE_KEY=$(ssh "${COMMON_SSH_OPTS[@]}" "$REMOTE" ${PROXY_ENV:+"$PROXY_ENV"} bash -s <<'AGE_EOF'
set -euo pipefail
HOST_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
if [[ ! -f "$HOST_KEY" ]]; then
  echo "WARN: $HOST_KEY not found. SSH host key may not have been generated yet." >&2
  exit 0
fi

# Source nix for ssh-to-age
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

if command -v ssh-to-age >/dev/null 2>&1; then
  ssh-to-age < "$HOST_KEY"
elif command -v nix >/dev/null 2>&1; then
  nix --extra-experimental-features 'nix-command flakes' \
    shell nixpkgs#ssh-to-age -c ssh-to-age < "$HOST_KEY"
else
  echo "WARN: neither ssh-to-age nor nix available to convert host key." >&2
  echo "Raw public key:"
  cat "$HOST_KEY"
fi
AGE_EOF
)

echo ""
echo "========================================"
echo "  Deployment complete!"
echo "  Host:       $REMOTE"
echo "  Flake:      $FLAKE_REF"
if [[ -n "$PROXY_URL" ]]; then
echo "  Proxy:      $PROXY_URL"
fi
if [[ "$USE_CN_MIRROR" == true ]]; then
echo "  CN mirror:  enabled"
fi
if [[ "$LOCAL_BUILD" == true ]]; then
echo "  Build:      local (pushed via nix copy)"
fi
echo "========================================"
if [[ -n "$AGE_KEY" && "$AGE_KEY" == age1* ]]; then
  echo ""
  echo "  Age public key (for .sops.yaml):"
  echo "  $AGE_KEY"
  echo ""
  echo "  To enable sops decryption on this machine, add the key"
  echo "  to .sops.yaml and run: sops updatekeys <secret-files>"
fi

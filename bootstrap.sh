#!/usr/bin/env bash
# Provider-agnostic bootstrap for an AI coding VPS (Hermes Agent + Claude Code + Pi + Sled + herdr).
# Ubuntu 24.04+ (x86_64 or arm64). Run as root. Idempotent: safe to re-run.
#
# Usage:
#   sudo ./bootstrap.sh [--user NAME] [--pubkey "ssh-ed25519 ..."|--pubkey-file PATH]
#                       [--no-tailscale] [--no-sled] [--no-hermes] [--no-herdr] [--no-claude] [--no-pi]
#                       [--skip-hardening] [--dry-run]
# Settings come from .env (see .env.example); flags override. Without systemd (e.g. a Docker
# test container) service, firewall and linger steps are skipped with a warning.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$REPO_DIR/.env" ]] && set -a && . "$REPO_DIR/.env" && set +a

VPS_USER="${VPS_USER:-agent}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-}"
WITH_TAILSCALE="${WITH_TAILSCALE:-1}" WITH_SLED="${WITH_SLED:-1}" WITH_HERMES="${WITH_HERMES:-1}" WITH_HERDR="${WITH_HERDR:-1}"
WITH_CLAUDE="${WITH_CLAUDE:-1}" WITH_PI="${WITH_PI:-1}" HARDEN=1 DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) VPS_USER="$2"; shift 2 ;;
    --pubkey) SSH_PUBKEY="$2"; shift 2 ;;
    --pubkey-file) SSH_PUBKEY="$(cat "$2")"; shift 2 ;;
    --no-tailscale) WITH_TAILSCALE=0; shift ;;
    --no-sled) WITH_SLED=0; shift ;;
    --no-hermes) WITH_HERMES=0; shift ;;
    --no-herdr) WITH_HERDR=0; shift ;;
    --no-claude) WITH_CLAUDE=0; shift ;;
    --no-pi) WITH_PI=0; shift ;;
    --skip-hardening) HARDEN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n 2,11p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
run() { if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }
as_user() { run sudo -iu "$VPS_USER" bash -lc "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo ./bootstrap.sh)" >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || echo "warning: tested on Ubuntu 24.04/26.04 only (found ${PRETTY_NAME:-unknown})" >&2
HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
[[ $HAS_SYSTEMD == 1 ]] || echo "warning: systemd not running; skipping service, firewall and linger steps" >&2
svc() { [[ $HAS_SYSTEMD == 1 ]] && run "$@" || echo "  [skip, no systemd] $*"; }

cd /  # user-level commands must not inherit an unreadable cwd (e.g. /root)
log "Base packages"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -y
run apt-get install -y sudo openssh-server ca-certificates curl gnupg git jq unzip xz-utils ripgrep tmux socat build-essential \
  python3 python3-venv python3-pip ufw fail2ban unattended-upgrades

log "User $VPS_USER"
if ! id "$VPS_USER" >/dev/null 2>&1; then
  run adduser --disabled-password --gecos "" "$VPS_USER"
fi
USER_HOME="$(getent passwd "$VPS_USER" | cut -d: -f6)"; USER_HOME="${USER_HOME:-/home/$VPS_USER}"
run usermod -aG sudo "$VPS_USER"
if [[ $DRY_RUN == 0 ]]; then
  echo "$VPS_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$VPS_USER"
  chmod 440 "/etc/sudoers.d/90-$VPS_USER"; visudo -cf "/etc/sudoers.d/90-$VPS_USER" >/dev/null
  install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "$USER_HOME/.ssh"
  touch "$USER_HOME/.ssh/authorized_keys"
  if [[ -n "$SSH_PUBKEY" ]] && ! grep -qF "$SSH_PUBKEY" "$USER_HOME/.ssh/authorized_keys"; then
    echo "$SSH_PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
  fi
  # Copy root's keys (cloud-init) if user has none yet
  if [[ ! -s "$USER_HOME/.ssh/authorized_keys" && -s /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
  fi
  chown "$VPS_USER:$VPS_USER" "$USER_HOME/.ssh/authorized_keys"; chmod 600 "$USER_HOME/.ssh/authorized_keys"
fi
[[ -s "$USER_HOME/.ssh/authorized_keys" || $DRY_RUN == 1 ]] || { echo "no SSH key for $VPS_USER; pass --pubkey. Refusing to harden SSH." >&2; HARDEN=0; }

if [[ $HARDEN == 1 ]]; then
  log "Hardening: sshd, ufw, fail2ban, unattended-upgrades"
  if [[ $DRY_RUN == 0 ]]; then
    install -m 644 "$REPO_DIR/config/etc/ssh/sshd_config.d/00-hardening.conf" /etc/ssh/sshd_config.d/00-hardening.conf
    mkdir -p /run/sshd; sshd -t
    [[ $HAS_SYSTEMD == 1 ]] && (systemctl reload ssh 2>/dev/null || systemctl reload sshd || true)
    install -m 644 "$REPO_DIR/config/etc/fail2ban/jail.d/defaults-debian.conf" /etc/fail2ban/jail.d/defaults-debian.conf
    install -m 644 "$REPO_DIR/config/etc/apt/apt.conf.d/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  fi
  svc ufw allow OpenSSH
  svc ufw --force enable
  svc systemctl enable --now fail2ban
fi

log "Node.js $NODE_MAJOR (NodeSource) + pnpm/yarn"
if ! have node || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]]; then
  run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
  run apt-get install -y nodejs
fi

log "GitHub CLI"
if ! have gh; then
  if [[ $DRY_RUN == 0 ]]; then
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -y && apt-get install -y gh
  else echo "[dry-run] install gh"; fi
fi

if [[ $WITH_TAILSCALE == 1 ]]; then
  log "Tailscale"
  have tailscale || run bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then run tailscale up --ssh=false --authkey "$TAILSCALE_AUTHKEY"
  else echo "Run 'sudo tailscale up' manually and log in (see CHECKLIST.md)."; fi
  [[ $HAS_SYSTEMD == 1 ]] && { run tailscale set --operator="$VPS_USER" || true; }
fi

log "Linger for $VPS_USER (user services survive logout/reboot)"
svc loginctl enable-linger "$VPS_USER"
# linger starts user@UID.service asynchronously; wait so install.sh can install the user units
if [[ $HAS_SYSTEMD == 1 && $DRY_RUN == 0 ]]; then
  uid="$(id -u "$VPS_USER")"; systemctl start "user@$uid.service" 2>/dev/null || true
  for _ in $(seq 20); do [[ -S /run/user/$uid/bus ]] && break; sleep 1; done
fi

log "User-level tooling"
# install.sh must be readable by the user: copy the repo into their home if it lives somewhere private (e.g. /root)
if sudo -u "$VPS_USER" test -r "$REPO_DIR/install.sh" 2>/dev/null; then USER_REPO="$REPO_DIR"; else
  USER_REPO="$USER_HOME/hermes-vps-kit"; run rm -rf "$USER_REPO"; run cp -r "$REPO_DIR" "$USER_REPO"; run chown -R "$VPS_USER:$VPS_USER" "$USER_REPO"; fi
as_user 'mkdir -p "$HOME/.npm-global" "$HOME/.local/bin" "$HOME/projects/logs"'
as_user 'npm config set prefix="$HOME/.npm-global"'
if [[ $DRY_RUN == 0 ]] && ! grep -q npm-global "$USER_HOME/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' >> "$USER_HOME/.profile"; chown "$VPS_USER:" "$USER_HOME/.profile"
fi
as_user 'npm i -g pnpm@10 yarn@1'
[[ $WITH_PI == 1 ]] && as_user 'npm i -g @mariozechner/pi-coding-agent'
[[ $WITH_CLAUDE == 1 ]] && as_user 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'
[[ $WITH_HERMES == 1 ]] && as_user '[ -x ~/.hermes/hermes-agent/.hermes/bin/hermes ] || curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
[[ $WITH_HERDR == 1 ]] && as_user 'command -v herdr >/dev/null || curl -fsSL https://herdr.dev/install.sh | sh'
if [[ $WITH_SLED == 1 ]]; then
  as_user 'npm i -g @zed-industries/claude-code-acp'
  as_user "[ -d ~/sled ] || git clone https://github.com/layercodedev/sled ~/sled; cd ~/sled && (git apply --check $USER_REPO/config/sled/pages.patch 2>/dev/null && git apply $USER_REPO/config/sled/pages.patch || true) && pnpm install"
fi

if [[ -n "$GIT_AUTHOR_NAME" && -n "$GIT_AUTHOR_EMAIL" ]]; then
  as_user "git config --global user.name $(printf %q "$GIT_AUTHOR_NAME") && git config --global user.email $(printf %q "$GIT_AUTHOR_EMAIL") && git config --global init.defaultBranch main"
fi

log "Dotfiles, Hermes profiles, systemd user units"
as_user "WITH_SLED=$WITH_SLED WITH_HERDR=$WITH_HERDR WITH_HERMES=$WITH_HERMES WITH_CLAUDE=$WITH_CLAUDE $USER_REPO/install.sh"

log "Done. Next: follow the manual steps in CHECKLIST.md (logins, tokens, Tailscale Serve)."

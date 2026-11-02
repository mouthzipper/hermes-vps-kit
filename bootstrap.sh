#!/usr/bin/env bash
# Provider-agnostic bootstrap for an AI coding VPS (Hermes Agent + Claude Code + Pi + Sled + herdr).
# Ubuntu 24.04+ (x86_64 or arm64). Run as root. Idempotent: safe to re-run.
#
# Usage:
#   sudo ./bootstrap.sh [--user NAME] [--pubkey "ssh-ed25519 ..."|--pubkey-file PATH]
#                       [--no-tailscale] [--no-sled] [--no-hermes] [--no-herdr] [--no-claude] [--no-pi]
#                       [--admin-sudo] [--tailscale-only-ssh] [--automatic-reboot HH:MM]
#                       [--skip-hardening] [--dry-run]
# Settings come from .env (see .env.example); flags override. Without systemd (e.g. a Docker
# test container) service, firewall and linger steps are skipped with a warning.
# Environment files are local operator input; single-quoted commands expand in the child shell.
# shellcheck disable=SC1091,SC2016
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$REPO_DIR/.env" ]] && set -a && . "$REPO_DIR/.env" && set +a

# Exact npm releases; bump deliberately after reviewing upstream release notes.
PNPM_VERSION=10.34.9
YARN_VERSION=1.22.22
PI_VERSION=0.73.1
CLAUDE_ACP_VERSION=0.16.2
ADMIN_SUDO=0 TAILSCALE_ONLY_SSH=0 AUTOMATIC_REBOOT=""
VPS_USER="${VPS_USER:-agent}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-}"
WITH_TAILSCALE="${WITH_TAILSCALE:-1}" WITH_SLED="${WITH_SLED:-1}" WITH_HERMES="${WITH_HERMES:-1}" WITH_HERDR="${WITH_HERDR:-1}"
WITH_CLAUDE="${WITH_CLAUDE:-1}" WITH_PI="${WITH_PI:-1}" HARDEN=1 DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) VPS_USER="${2:?--user requires a name}"; shift 2 ;;
    --admin-sudo) ADMIN_SUDO=1; shift ;;
    --tailscale-only-ssh) TAILSCALE_ONLY_SSH=1; shift ;;
    --automatic-reboot) AUTOMATIC_REBOOT="${2:?--automatic-reboot requires HH:MM}"; shift 2 ;;
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

[[ "$VPS_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$VPS_USER" != root ]] || { echo "invalid --user: use a non-root Linux username" >&2; exit 2; }
[[ -z "$AUTOMATIC_REBOOT" || "$AUTOMATIC_REBOOT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "invalid reboot time: expected HH:MM" >&2; exit 2; }
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || { echo "invalid NODE_MAJOR" >&2; exit 2; }
[[ $TAILSCALE_ONLY_SSH == 0 || ( $WITH_TAILSCALE == 1 && $HARDEN == 1 ) ]] || { echo "--tailscale-only-ssh requires Tailscale and hardening" >&2; exit 2; }

log() { printf '\n==> %s\n' "$*"; }
run() { if [[ $DRY_RUN == 1 ]]; then local arg; printf '[dry-run]'; for arg in "$@"; do
  [[ -z "${TAILSCALE_AUTHKEY:-}" ]] || arg="${arg//"$TAILSCALE_AUTHKEY"/[REDACTED]}"
  printf ' %q' "$arg"
  done; printf '\n' ; else "$@"; fi; }
as_user() { run sudo -iu "$VPS_USER" bash -lc "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 || $DRY_RUN == 1 ]] || { echo "run as root (sudo ./bootstrap.sh)" >&2; exit 1; }
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
USER_HOME="$(getent passwd "$VPS_USER" | cut -d: -f6 || true)"; USER_HOME="${USER_HOME:-/home/$VPS_USER}"
if [[ $DRY_RUN == 0 ]]; then
  if [[ $ADMIN_SUDO == 1 ]]; then
    sudoers_tmp="$(mktemp)"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$VPS_USER" > "$sudoers_tmp"
    visudo -cf "$sudoers_tmp" >/dev/null
    install -m 440 "$sudoers_tmp" "/etc/sudoers.d/90-$VPS_USER"
    rm -f "$sudoers_tmp"
  else
    # Revoke the kit's grant on re-runs; leave unrelated administrator policy alone.
    rm -f "/etc/sudoers.d/90-$VPS_USER"
  fi
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
    sed "s/__VPS_USER__/$VPS_USER/g" "$REPO_DIR/config/etc/ssh/sshd_config.d/00-hardening.conf" > /etc/ssh/sshd_config.d/00-hardening.conf
    chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf
    mkdir -p /run/sshd; sshd -t
    [[ $HAS_SYSTEMD == 1 ]] && (systemctl reload ssh 2>/dev/null || systemctl reload sshd || true)
    install -m 644 "$REPO_DIR/config/etc/fail2ban/jail.d/defaults-debian.conf" /etc/fail2ban/jail.d/defaults-debian.conf
    install -m 644 "$REPO_DIR/config/etc/apt/apt.conf.d/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' > /etc/apt/apt.conf.d/52kit-reboot
    if [[ -n "$AUTOMATIC_REBOOT" ]]; then
      printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$AUTOMATIC_REBOOT" > /etc/apt/apt.conf.d/52kit-reboot
    fi
  fi
  if [[ ! -f /etc/ssh/tailscale-only-ssh ]]; then svc ufw allow OpenSSH; fi
  svc ufw --force enable
  svc systemctl enable --now fail2ban
fi

log "Node.js $NODE_MAJOR (NodeSource) + pnpm/yarn"
if ! have node || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]]; then
  if [[ $DRY_RUN == 0 ]]; then
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    chmod 644 /etc/apt/keyrings/nodesource.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update -y
  else echo "[dry-run] configure signed NodeSource apt repository"; fi
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
  if ! have tailscale; then
    if [[ $DRY_RUN == 0 ]]; then
      install -d -m 755 /etc/apt/keyrings
      curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" -o /etc/apt/keyrings/tailscale.gpg
      chmod 644 /etc/apt/keyrings/tailscale.gpg
      echo "deb [signed-by=/etc/apt/keyrings/tailscale.gpg] https://pkgs.tailscale.com/stable/ubuntu ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/tailscale.list
      apt-get update -y; apt-get install -y tailscale
    else echo "[dry-run] configure signed Tailscale apt repository and install tailscale"; fi
  fi
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    if [[ $DRY_RUN == 0 ]]; then
      key_file="$(mktemp)"; chmod 600 "$key_file"
      trap 'shred -u "$key_file"' EXIT
      printf '%s' "$TAILSCALE_AUTHKEY" > "$key_file"
      tailscale up --ssh=false --auth-key="file:$key_file"
      shred -u "$key_file"; trap - EXIT
      unset TAILSCALE_AUTHKEY
    else echo "[dry-run] tailscale up --ssh=false --auth-key=file:[REDACTED]"; fi
  else echo "Run 'tailscale up' as an administrator manually and log in (see CHECKLIST.md)."; fi
  [[ $HAS_SYSTEMD == 1 ]] && { run tailscale set --operator="$VPS_USER" || true; }
fi

if [[ $TAILSCALE_ONLY_SSH == 1 ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    echo "[dry-run] require active tailnet SSH session; allow tailscale0:22 then remove public OpenSSH/22 rules"
  else
    [[ $HAS_SYSTEMD == 1 ]] || { echo "tailnet-only SSH requires systemd" >&2; exit 1; }
    tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null
    tailnet_ip="$(tailscale ip -4)"
    [[ "${SUDO_USER:-}" == "$VPS_USER" && -n "${SSH_CONNECTION:-}" && "${SSH_CONNECTION%% *}" != "$tailnet_ip" && "$(awk '{print $3}' <<< "$SSH_CONNECTION")" == "$tailnet_ip" ]] || {
      echo "Refusing to close public SSH: reconnect as $VPS_USER over the Tailscale IPv4 address first, preserve SSH_CONNECTION through sudo, then re-run." >&2; exit 1;
    }
    [[ -s "$USER_HOME/.ssh/authorized_keys" ]] || { echo "No agent SSH keys; refusing firewall lockdown" >&2; exit 1; }
    ufw allow in on tailscale0 to any port 22 proto tcp
    ufw --force delete allow OpenSSH
    ufw --force delete allow 22 || true
    ufw --force delete allow 22/tcp || true
    # Catch any other public SSH allow rules before declaring success.
    if ufw status | awk '/ALLOW/ && /(^22|OpenSSH)/ && !/tailscale0/ {found=1} END {exit !found}'; then
      echo "Additional public SSH rules remain; remove them manually after checking tailnet access." >&2; exit 1
    fi
    install -m 644 /dev/null /etc/ssh/tailscale-only-ssh
  fi
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
  USER_REPO="$USER_HOME/hermes-vps-kit"
  if [[ -e "$USER_REPO" ]]; then
    [[ -d "$USER_REPO/.git" || $DRY_RUN == 1 ]] || { echo "Existing $USER_REPO is not a git checkout; refusing to overwrite" >&2; exit 1; }
    as_user "git -C $(printf %q "$USER_REPO") pull --ff-only"
  else
    # Clone tracked files only: never copy .env or profiles.local into the agent home.
    run git clone --no-hardlinks "$REPO_DIR" "$USER_REPO"
    source_origin="$(git -C "$REPO_DIR" remote get-url origin)"
    run git -C "$USER_REPO" remote set-url origin "$source_origin"
    run chown -R "$VPS_USER:$VPS_USER" "$USER_REPO"
  fi
fi
USER_REPO_Q="$(printf %q "$USER_REPO")"
as_user 'mkdir -p "$HOME/.npm-global" "$HOME/.local/bin" "$HOME/projects/logs"'
as_user 'npm config set prefix="$HOME/.npm-global"'
if [[ $DRY_RUN == 0 ]] && ! grep -q npm-global "$USER_HOME/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' >> "$USER_HOME/.profile"; chown "$VPS_USER:" "$USER_HOME/.profile"
fi
as_user "npm i -g pnpm@$PNPM_VERSION yarn@$YARN_VERSION"
[[ $WITH_PI == 1 ]] && as_user "npm i -g @mariozechner/pi-coding-agent@$PI_VERSION"
[[ $WITH_CLAUDE == 1 ]] && as_user 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'
[[ $WITH_HERMES == 1 ]] && as_user '[ -x ~/.hermes/hermes-agent/.hermes/bin/hermes ] || curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
[[ $WITH_HERDR == 1 ]] && as_user 'command -v herdr >/dev/null || curl -fsSL https://herdr.dev/install.sh | sh'
if [[ $WITH_SLED == 1 ]]; then
  as_user "npm i -g @zed-industries/claude-code-acp@$CLAUDE_ACP_VERSION"
  SLED_REV="$(cat "$REPO_DIR/config/sled/UPSTREAM_REV")"
  [[ "$SLED_REV" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid Sled revision" >&2; exit 1; }
  as_user "[ -d ~/sled ] || git clone https://github.com/layercodedev/sled ~/sled; cd ~/sled && git fetch origin $SLED_REV && git checkout --detach $SLED_REV && (git apply --reverse --check $USER_REPO_Q/config/sled/pages.patch 2>/dev/null || git apply $USER_REPO_Q/config/sled/pages.patch) && pnpm install --frozen-lockfile"
fi

if [[ -n "$GIT_AUTHOR_NAME" && -n "$GIT_AUTHOR_EMAIL" ]]; then
  as_user "git config --global user.name $(printf %q "$GIT_AUTHOR_NAME") && git config --global user.email $(printf %q "$GIT_AUTHOR_EMAIL") && git config --global init.defaultBranch main"
fi

log "Dotfiles, Hermes profiles, systemd user units"
INSTALL_ENV=""
for setting in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL HERMES_PROVIDER HERMES_MODEL HERMES_SUBAGENT_MODEL HERMES_BASE_URL HERMES_API_KEY_ENV HERMES_MAX_SUBAGENTS HERMES_PROFILES_DIR WITH_SKILLS PSTACK_REF HERDR_SKILL_REF TELEGRAM_USER_ID TELEGRAM_ALLOWED_USERS REVIEW_ORGS TRUSTED_AUTHORS TAILSCALE_IP SLED_TAILNET_SOCAT PROJECTS HERDR_SESSIONS CLAUDE_MODEL CLAUDE_SUBAGENT_MODEL; do
  [[ -v $setting ]] && INSTALL_ENV+=" $setting=$(printf %q "${!setting}")"
done
as_user "$INSTALL_ENV SKIP_REPO_ENV=1 WITH_SLED=$WITH_SLED WITH_HERDR=$WITH_HERDR WITH_HERMES=$WITH_HERMES WITH_CLAUDE=$WITH_CLAUDE $USER_REPO_Q/install.sh"

log "Done. Next: follow the manual steps in CHECKLIST.md (logins, tokens, Tailscale Serve)."

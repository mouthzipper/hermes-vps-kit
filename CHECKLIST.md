# Setup checklist

Do these in order. ☐ = manual, 🤖 = done by `bootstrap.sh` / `install.sh`.

## 1. Create the server (manual)
- [ ] Ubuntu **24.04 LTS or newer**, ≥ 8 GB RAM (16 GB if you run 2 coding jobs), ≥ 80 GB disk. x86_64 or arm64 (all tools ship arm64; x86 is the tested path).
- [ ] Add your SSH public key at creation time.
- Provider notes:
  - **Hetzner**: CX33/CX43 (x86) or CAX (arm). Login user is `root`. Optional Hetzner Cloud Firewall: allow TCP 22 inbound only (Tailscale needs no inbound port).
  - **OVHcloud**: default user `ubuntu` (sudo), root SSH disabled; run bootstrap with `sudo`. OVH has an optional "Network Firewall" — allow 22.
  - **AWS EC2**: default user `ubuntu`. Security group: inbound TCP 22 from your IP (or 0.0.0.0/0 key-only), nothing else. Use gp3 ≥ 80 GB. Graviton (t4g/m7g) = arm64 and cheaper. Elastic IP optional.
  - **DigitalOcean**: Droplet user `root`. Cloud Firewall: inbound 22 only.
- [ ] Note the public IP → `<PUBLIC_IP>`.

## 2. Bootstrap (automated)
- [ ] `ssh root@<PUBLIC_IP>` (or `ubuntu@` on OVH/EC2, then `sudo -i`)
- [ ] `git clone https://github.com/<you>/hermes-vps-kit && cd hermes-vps-kit` (or your private fork with your own `profiles.local/`)
- [ ] `cp .env.example .env` and edit it (every variable is explained in the README; defaults work)
- [ ] `./bootstrap.sh` as root (flags: `--no-sled --no-herdr --no-tailscale --no-hermes --no-claude --no-pi --skip-hardening --dry-run`)
  - 🤖 apt base packages, user + NOPASSWD sudo, authorized_keys
  - 🤖 sshd key-only (`00-hardening.conf`), ufw (OpenSSH only), fail2ban sshd jail, unattended-upgrades
  - 🤖 Node 22 (NodeSource), npm prefix `~/.npm-global`, pnpm, yarn, gh, Tailscale package
  - 🤖 linger, Claude Code (native installer), Pi (`@mariozechner/pi-coding-agent`), Hermes Agent (official installer), herdr (official installer, SHA-256 verified)
  - 🤖 Sled clone + `pages.patch` + `pnpm install`, `claude-code-acp`
  - 🤖 dotfiles, Hermes config + profiles (profiles.local/ or examples/profiles), pstack + herdr skills, systemd user units (enabled), herdr sessions
- [ ] **Before closing the root session**, in a new terminal confirm `ssh <VPS_USER>@<PUBLIC_IP> 'sudo -n true && echo ok'`.

## 3. Logins and tokens (manual, as `<VPS_USER>`)
- [ ] **Tailscale**: `sudo tailscale up` → open the URL, log in (no DNS needed; MagicDNS gives `<host>.<tailnet>.ts.net`). Then `sudo tailscale set --operator=$USER`.
- [ ] **Tailscale Serve for Sled** (tailnet-only HTTPS): enable HTTPS in the admin console (DNS → HTTPS certificates), then `tailscale serve --bg 8787`. Never use `tailscale funnel`.
- [ ] **GitHub**: `gh auth login` (HTTPS, browser/device code) then `gh auth setup-git`.
- [ ] **Claude Code** (if installed): `claude` → `/login`. Models come from `CLAUDE_MODEL` / `CLAUDE_SUBAGENT_MODEL` in `.env`, or Claude Code defaults.
- [ ] **Hermes model**: `hermes model` → pick your provider and log in, or put its API key in `~/.hermes/.env`. If you set `HERMES_*` model variables in `.env`, make sure the ids exist for that provider (README → Choosing your model); fix and re-run `./install.sh` otherwise.
- [ ] **Telegram**: @BotFather → `/newbot` → token. Get your numeric user id (@userinfobot). Put the token and id in `~/.hermes/.env` (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`), set `TELEGRAM_USER_ID` in `.env` and re-run `./install.sh`.
- [ ] Optional: Pi login (`pi` → `/login`).
- [ ] Reviewer: set `REVIEW_ORGS` in `.env`, re-run `./install.sh`.
- [ ] Clone your repos into `~/projects` (`gh repo clone org/repo ~/projects/repo`).

## 4. Start services
- [ ] `systemctl --user start hermes-gateway sled`

## 5. Verify
- [ ] `./scripts/verify.sh` (tools, auth, services, linger, ufw, fail2ban, sshd)
- [ ] `hermes -p engineer chat -q 'say which model you are and spawn one subagent to echo hi'` → answers with your chosen model; the subagent runs
- [ ] `claude -p 'use the executor subagent to say hi and its model id'` → both answer
- [ ] Telegram: message the bot → reply
- [ ] Phone on tailnet: `https://<host>.<tailnet>.ts.net` opens Sled
- [ ] `herdr session list` → all sessions running; attach `ssh <user>@<host>` then `herdr session attach <name>`
- [ ] `sudo reboot`, then re-run `verify.sh` (user services come back via linger)

## Attach cheatsheet
- SSH: `ssh <user>@<PUBLIC_IP>` or `ssh <user>@<tailscale-host>`
- herdr: `herdr session attach <name>`; detach `ctrl+b q`; from a laptop with herdr: `herdr --remote <user>@<host> --session <name>`
- Hermes CLI: `hermes -p <profile> chat`

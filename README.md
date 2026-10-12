# hermes-vps-kit

Turn a fresh Ubuntu VPS (Hetzner, OVHcloud, AWS EC2, DigitalOcean, ...) into a hardened, always-on AI coding box:

- **Hermes Agent**: Telegram gateway plus profiles (`engineer`, `reviewer`) that orchestrate subagents, on any model provider Hermes supports
- **Claude Code** (optional): with `executor` / `reviewer` subagents
- **Pi** coding agent, **Sled** (phone-friendly web UI, private via Tailscale), **herdr** (one persistent terminal session per project)
- **pstack** and **herdr** skills installed for every agent
- Hardening: key-only SSH, ufw (SSH only), fail2ban, unattended-upgrades; Tailscale for private access

## Prerequisites

- A server running **Ubuntu 24.04 LTS or newer** (x86_64 or arm64), **8 GB RAM minimum** (16 GB for several agents in parallel), 80 GB disk, with your SSH key added at creation.
- Accounts you will log in to after install: GitHub, a model provider for Hermes (subscription login or API key), Claude (only if you install Claude Code), Tailscale (optional), Telegram bot via @BotFather (optional).

## Quickstart

```bash
# 1. on the server, as root (or `sudo -i` on Ubuntu/OVH/EC2 images)
git clone https://github.com/<you>/hermes-vps-kit && cd hermes-vps-kit
cp .env.example .env && nano .env        # see "Configuration" below; defaults work
./bootstrap.sh --dry-run                 # optional preview
./bootstrap.sh                           # system setup, then runs install.sh as VPS_USER

# 2. in a NEW terminal, before closing the root one, confirm you can still log in
ssh <VPS_USER>@<server-ip> 'sudo -n true && echo ok'

# 3. as VPS_USER: log in to the tools (details in CHECKLIST.md)
sudo tailscale up; gh auth login && gh auth setup-git; claude; hermes model   # skip what you didn't install
nano ~/.hermes/.env                      # TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS

# 4. start services and verify
systemctl --user start hermes-gateway sled
./scripts/verify.sh
```

`bootstrap.sh` copies the kit to `~VPS_USER/hermes-vps-kit` if the user can't read the original folder (e.g. it was cloned into `/root`). To re-apply only the user-level part later (after editing `.env` or profiles), run `./install.sh` as VPS_USER from that folder. Both scripts are idempotent; replaced files are backed up as `*.bak-<timestamp>`.

`bootstrap.sh` flags: `--user NAME`, `--pubkey "ssh-ed25519 ..."`, `--pubkey-file PATH`, `--no-tailscale`, `--no-sled`, `--no-hermes`, `--no-herdr`, `--no-claude`, `--no-pi`, `--skip-hardening`, `--dry-run`.
`install.sh` toggles (env): `WITH_HERMES`, `WITH_SLED`, `WITH_HERDR`, `WITH_SKILLS` (1/0), `SKIP_SYSTEMD=1`.

## Configuration (.env)

| Variable | Default | Meaning |
|---|---|---|
| `VPS_USER` | `agent` | Linux user that runs everything; created if missing, gets passwordless sudo |
| `SSH_PUBKEY` | empty | Public key for that user; empty = copy root's `authorized_keys`. With no key at all, SSH hardening is skipped so you can't lock yourself out |
| `NODE_MAJOR` | `22` | Node.js major version (NodeSource) |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | placeholders | Git identity for commits made by agents; also written into the profiles |
| `TAILSCALE_AUTHKEY` | empty | Optional one-off key for unattended `tailscale up`. Never commit it |
| `TAILSCALE_IP` / `SLED_TAILNET_SOCAT` | empty / `0` | Only for the optional socat unit exposing Sled on the tailnet IP (default is `tailscale serve`) |
| `PROJECTS` | `project-a project-b` | Folders created under `~/projects` |
| `HERDR_SESSIONS` | `project-a:project-a ...` | `name:dir` pairs (dir relative to `~/projects`, `.` = `~/projects`); one herdr server + workspace each. Empty = none |
| `WITH_HERMES` `WITH_CLAUDE` `WITH_PI` `WITH_SLED` `WITH_HERDR` `WITH_TAILSCALE` | `1` | Install (1) or skip (0) each component. Same as the `--no-*` flags |
| `HERMES_PROVIDER` | empty | Hermes provider id (see Choosing your model). Empty = pick later with `hermes model` |
| `HERMES_MODEL` | empty | Orchestrator model id from that provider |
| `HERMES_SUBAGENT_MODEL` | empty | Model for delegated subagents; empty = Hermes default |
| `HERMES_BASE_URL` | empty | Endpoint for `custom`/self-hosted OpenAI-compatible servers |
| `HERMES_API_KEY_ENV` | empty | Name of the env var that holds the API key; the key itself goes in `~/.hermes/.env` |
| `CLAUDE_MODEL` / `CLAUDE_SUBAGENT_MODEL` | empty | Claude Code main and subagent model; empty = Claude Code defaults |
| `HERMES_MAX_SUBAGENTS` | `2` | Parallel subagents; 2 for 8 GB RAM, ~4 for 16 GB |
| `HERMES_PROFILES_DIR` | empty | Where profiles come from: this dir, else `profiles.local/`, else `examples/profiles/` |
| `TELEGRAM_USER_ID` | empty | Your numeric Telegram id (@userinfobot); sets the gateway home channel. Bot token goes in `~/.hermes/.env` |
| `REVIEW_ORGS` | empty | Space-separated GitHub orgs/users the `reviewer` profile reviews. Written to `~/.hermes/profiles/reviewer/.env` |
| `PSTACK_REF` | `main` | Git ref of `cursor/plugins` used for pstack skills |

## Profiles

`examples/profiles/` holds two generic Hermes profiles:

- **engineer**: implements a request end to end, delegates to subagents and Claude Code, verifies, pushes a branch and opens a PR. Never force-pushes or merges.
- **reviewer**: reviews PRs labeled `Ready for Code Review` in `REVIEW_ORGS`, posts one evidence-backed comment per head SHA, and only fixes PRs owned by the logged-in `gh` user. Local builds are blocked for it by a Claude Code hook (`PR_REVIEWER_NO_BUILD=1` in its `.env`).

Each profile gets a shortcut in `~/.local/bin` (`engineer "fix the flaky test"` = `hermes -p engineer ...`).

Keep your own or client-specific profiles out of git: put them in `profiles.local/<name>/` (git-ignored) or point `HERMES_PROFILES_DIR` elsewhere. Placeholders rendered at install time: `__HOME__`, `__GIT_AUTHOR_NAME__`, `__GIT_AUTHOR_EMAIL__`, `__TAILSCALE_IP__`. A profile without its own `config.yaml` gets the config generated from `.env`; add a `config.yaml` to a profile to override it.

## Choosing your model

The kit doesn't pick a model for you. Either:

- leave the `HERMES_*` model variables empty and run `hermes model` after install to choose a provider and log in, or
- set them in `.env` and re-run `./install.sh`. Examples:

```bash
# subscription login (then `hermes model` once to authenticate)
HERMES_PROVIDER=openai-codex   HERMES_MODEL=<model id>
# API-key provider (key in ~/.hermes/.env as that provider's variable, e.g. OPENROUTER_API_KEY)
HERMES_PROVIDER=openrouter     HERMES_MODEL=<vendor/model>   HERMES_SUBAGENT_MODEL=<cheaper model>
# any OpenAI-compatible server (vLLM, Ollama, llama.cpp, a gateway)
HERMES_PROVIDER=custom HERMES_BASE_URL=http://127.0.0.1:11434/v1 HERMES_MODEL=<model> HERMES_API_KEY_ENV=MY_LLM_API_KEY
```

The generated `~/.hermes/config.yaml` and each profile's `config.yaml` contain only these keys plus subagent limits; secrets are never written to config. Run `hermes model` to see what your provider offers. Claude Code models are set the same way with `CLAUDE_MODEL` / `CLAUDE_SUBAGENT_MODEL`, or left to Claude Code's defaults.

## Layout

| Path | What |
|---|---|
| `bootstrap.sh` | Root: packages, user, hardening, Node, gh, Tailscale, agents, Sled, then `install.sh` as the user |
| `install.sh` | User: dotfiles, Hermes config/profiles, skills, projects, systemd user units, herdr sessions |
| `config/` | sshd, fail2ban, unattended-upgrades; Sled patch |
| `dotfiles/` | `~/.claude` settings, subagents, reviewer no-build hook; Sled launcher |
| `hermes/` | `env.example` template for `~/.hermes/.env` |
| `examples/profiles/` | `engineer` and `reviewer` |
| `systemd/user/` | `hermes-gateway`, `sled`, `sled-tailnet` (optional), `herdr@<session>` |
| `scripts/` | `verify.sh`, `install-skills.sh`, `herdr-sessions.sh` |

## Notes

- Tested end to end in a fresh `ubuntu:24.04` Docker container (no systemd, so service/firewall steps are skipped there). Report issues from real providers.
- `VPS_USER` gets passwordless sudo. Remove `/etc/sudoers.d/90-<user>` if you don't want that.
- Never use `tailscale funnel` for Sled; it has no auth of its own. Use `tailscale serve`.

## License

MIT

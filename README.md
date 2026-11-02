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
install -m 600 .env.example .env && nano .env        # see "Configuration" below
./bootstrap.sh --dry-run                 # optional preview
./bootstrap.sh                           # system setup, then runs install.sh as VPS_USER
# Empty TELEGRAM_ALLOWED_USERS returns an error after installing independent units.
# Configure ~/.hermes/.env and re-run install.sh below before starting the gateway.

# 2. in a NEW terminal, before closing the root one, confirm you can still log in
ssh <VPS_USER>@<server-ip> 'id -un'

# 3. as VPS_USER: log in to the tools (details in CHECKLIST.md)
# Enroll Tailscale via the administrator console first if needed.
gh auth login && gh auth setup-git; claude; hermes model   # skip what you didn't install
nano ~/.hermes/.env                      # TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS

# 4. start services and verify
./install.sh                            # re-apply after setting the Telegram allowlist
systemctl --user start hermes-gateway sled
./scripts/verify.sh
```

`bootstrap.sh` clones tracked kit files to `~VPS_USER/hermes-vps-kit` if the user can't read the original folder (e.g. it was cloned into `/root`). To re-apply only the user-level part later (after editing `.env` or profiles), run `./install.sh` as VPS_USER from that folder. The clone never receives `.env` or `profiles.local/`; selected non-secret settings are passed to `install.sh`. Bootstrap sets `SKIP_REPO_ENV=1` for user scripts so they never source the root-owned configuration, even when the checkout itself is readable. A cloned checkout retains the source origin (including forks). Custom profile sources must be readable by the agent user. Existing user checkouts update with `git pull --ff-only`, preserving `profiles.local/` and refusing conflicts. For user-level reconfiguration, create a separate `.env` with `install -m 600 .env.example .env` and omit `TAILSCALE_AUTHKEY`. Both scripts are idempotent; replaced files are backed up as `*.bak-<timestamp>`.

`bootstrap.sh` flags: `--user NAME`, `--pubkey "ssh-ed25519 ..."`, `--pubkey-file PATH`, `--no-tailscale`, `--no-sled`, `--no-hermes`, `--no-herdr`, `--no-claude`, `--no-pi`, `--admin-sudo`, `--tailscale-only-ssh`, `--automatic-reboot HH:MM`, `--skip-hardening`, `--dry-run`.
`install.sh` toggles (env): `WITH_HERMES`, `WITH_SLED`, `WITH_HERDR`, `WITH_SKILLS` (1/0), `SKIP_SYSTEMD=1`.

## Configuration (.env)

| Variable | Default | Meaning |
|---|---|---|
| `VPS_USER` | `agent` | Linux user that runs everything; created if missing; no sudo grant unless `--admin-sudo` is passed |
| `SSH_PUBKEY` | empty | Public key for that user; empty = copy root's `authorized_keys`. With no key at all, SSH hardening is skipped so you can't lock yourself out |
| `NODE_MAJOR` | `22` | Node.js major version (NodeSource) |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | placeholders | Git identity for commits made by agents; also written into the profiles |
| `TAILSCALE_AUTHKEY` | empty | Optional one-off, tagged, expiring key for unattended `tailscale up`; restrict its tag ACLs. Never commit it |
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
| `TRUSTED_AUTHORS` | empty | Exact space-separated GitHub author logins allowed to run PR code; otherwise static review only |
| `TELEGRAM_ALLOWED_USERS` | empty | Explicit Telegram user IDs; also set in `~/.hermes/.env`. Gateway enable is refused while empty; other units are still installed |
| `REVIEW_ORGS` | empty | Space-separated GitHub orgs/users the `reviewer` profile reviews. Written to `~/.hermes/profiles/reviewer/.env` |
| `PSTACK_REF` / `HERDR_SKILL_REF` | Pinned SHAs in `.env.example` | Full commit SHAs for pstack and herdr skills; review upstream changes before bumping |

## Profiles

`examples/profiles/` holds two generic Hermes profiles:

- **engineer**: implements a request end to end, delegates to subagents and Claude Code, verifies, pushes a branch and opens a PR. Never force-pushes or merges.
- **reviewer**: reviews PRs labeled `Ready for Code Review` in `REVIEW_ORGS`, posts one evidence-backed comment per head SHA, and only fixes PRs owned by the logged-in `gh` user. Tests, lint, type checks and other PR code run only for exact logins in `TRUSTED_AUTHORS`; empty means static review for every author. Local builds are blocked for it by a Claude Code hook (`PR_REVIEWER_NO_BUILD=1` in its `.env`).

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
- `VPS_USER` gets no sudo grant by default. `--admin-sudo` explicitly grants passwordless sudo, which gives every agent root access; avoid it for unattended agents. Re-running without the flag removes the kit's sudoers grant. Existing administrator group memberships and unrelated sudo rules are left to the operator.
- Never use `tailscale funnel` for Sled; it has no auth of its own. Use `tailscale serve`.

## Hardening operations

Keep a provider console or separate administrator session available. SSH permits only `VPS_USER` and disables root and password login; validate a fresh user key login before closing the original session. Administrative commands in this guide require a separate administrator or provider console by default. `verify.sh` uses `sudo -n` for privileged checks and reports failures if that access is unavailable; an administrator can run those checks separately.

For tailnet-only SSH, first enroll Tailscale, then open a fresh SSH connection as `VPS_USER` to the node's Tailscale IPv4 address. From that session an authorized administrator can run `sudo --preserve-env=SSH_CONNECTION ./bootstrap.sh --tailscale-only-ssh` (repeat any component flags). The script requires that session and working Tailscale, allows TCP 22 on `tailscale0`, then deletes the public OpenSSH/22 rules. Keep console access for recovery. Standard runs preserve the existing tailnet-only firewall policy once enabled.

Automatic reboots remain disabled unless `--automatic-reboot HH:MM` is passed (server local time). User services use `NoNewPrivileges`, `PrivateTmp` and `ProtectSystem=strict`, with home and the user runtime directory writable for agents. This requires systemd user filesystem namespaces; check service journals on hosts that restrict unprivileged user namespaces.

NodeSource, GitHub CLI and Tailscale use apt repositories scoped with `signed-by` keyrings. npm globals, Sled, downloaded skills and the Claude marketplace have explicit version/commit pins. Review upstream diffs and update the corresponding variables, `config/sled/UPSTREAM_REV` (plus patch), or marketplace `source.ref` deliberately. Claude supports marketplace `ref` pins ([reference](https://code.claude.com/docs/en/plugins/marketplace-reference)); plugins that fetch separate external sources still require their own review. The Claude, Hermes and herdr native installers and their self-updates remain upstream-controlled downloads. HTTPS and download hashes do not establish independent authenticity if upstream is compromised.

Review untrusted PRs statically. To execute untrusted code, use a separate throwaway container without `gh` login, host credentials, secrets, host mounts or privileged access. A policy prompt and the build hook are guardrails, not a sandbox.

## License

MIT

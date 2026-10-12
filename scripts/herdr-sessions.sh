#!/usr/bin/env bash
# One persistent herdr server per project (systemd user unit herdr@<name>), each with a workspace at its dir.
# HERDR_SESSIONS="name:relative/dir ..." (relative to ~/projects; "." = ~/projects)
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && set -a && . "$REPO_DIR/.env" && set +a
SESSIONS="${HERDR_SESSIONS:-}"
[[ -z "$SESSIONS" ]] && { echo "HERDR_SESSIONS empty in .env, no herdr sessions created"; exit 0; }
for entry in $SESSIONS; do
  name="${entry%%:*}"; dir="$HOME/projects/${entry#*:}"; mkdir -p "$dir"
  systemctl --user enable --now "herdr@$name.service"
done
sleep 3
for entry in $SESSIONS; do
  name="${entry%%:*}"; dir="$(cd "$HOME/projects/${entry#*:}" && pwd)"
  if ! herdr --session "$name" workspace list 2>/dev/null | grep -q "\"label\":\"$name\""; then
    herdr --session "$name" workspace create --cwd "$dir" --label "$name" --no-focus >/dev/null
  fi
done
herdr session list

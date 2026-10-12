#!/usr/bin/env bash
# Sled launcher: binds only to 127.0.0.1 (exposed to tailnet via `tailscale serve`)
set -uo pipefail
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export WRANGLER_SEND_METRICS=false
cd "$HOME/sled/server-client" || exit 1
AGENT_MANAGER_HOST=127.0.0.1 ACP_PROXY_HOST=127.0.0.1 pnpm start &
cd "$HOME/sled/app" || exit 1
pnpm exec wrangler dev --ip 127.0.0.1 --port 8787 --persist-to .wrangler/state &
wait -n
echo "a Sled process exited; stopping so systemd restarts it" >&2
exit 1

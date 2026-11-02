#!/usr/bin/env bash
# Post-install health check. Run as the VPS user.
# Child-shell expressions below must expand at check time.
# shellcheck disable=SC2016
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
FAILURES=0
ok() { printf '  [ok]   %s\n' "$1"; } ; bad() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
echo "== tools"
for c in node pnpm gh git claude pi hermes herdr tailscale; do chk "$c" command -v "$c"; done
echo "== auth"
chk "gh auth" gh auth status
chk "claude login (tiny call)" timeout 90 claude -p "reply ok"
chk "hermes model reply" timeout 120 hermes -p engineer chat -q "reply ok"
chk "tailscale up" tailscale status
echo "== services"
for u in hermes-gateway sled; do chk "$u" systemctl --user is-active "$u"; done
for u in $(systemctl --user list-units 'herdr@*' --plain --no-legend | awk '{print $1}'); do chk "$u" systemctl --user is-active "$u"; done
chk "linger" bash -c "loginctl show-user $USER -p Linger | grep -q yes"
echo "== security"
chk "ufw active" bash -c "sudo -n ufw status | grep -q 'Status: active'"
chk "fail2ban sshd jail" sudo -n fail2ban-client status sshd
chk "password auth off" bash -c "sudo -n sshd -T | grep -q '^passwordauthentication no'"
chk "root SSH disabled" bash -c "sudo -n sshd -T | grep -qx 'permitrootlogin no'"
chk "SSH restricted to current user" bash -c 'sudo -n sshd -T | grep -qx "allowusers $(id -un)"'
if [[ -f /etc/ssh/tailscale-only-ssh ]]; then
  chk "tailnet-only SSH firewall" bash -o pipefail -c 'sudo -n ufw status | awk '\''/22.*tailscale0.*ALLOW/ {tailnet=1} /ALLOW/ && /(^22|OpenSSH)/ && !/tailscale0/ {public=1} END {exit !(tailnet && !public)}'\'''
fi
for u in hermes-gateway sled sled-tailnet herdr@check; do
  chk "$u NoNewPrivileges" bash -o pipefail -c 'systemctl --user show "$1" -p NoNewPrivileges --value | grep -qx yes' _ "$u"
done
for u in hermes-gateway sled sled-tailnet herdr@check; do
  chk "$u filesystem sandbox" bash -o pipefail -c '[[ $(systemctl --user show "$1" -p PrivateTmp --value) == yes && $(systemctl --user show "$1" -p ProtectSystem --value) == strict ]]' _ "$u"
done
[[ $FAILURES == 0 ]]

#!/bin/sh
# register-openco3.sh <hostname> — authorize an egress box on openco3.
# Run ON openco3 (☁️), from the repo clone, as root:
#   ./egress/register-openco3.sh home
# Idempotent: ensures the tunnel landing zone exists, installs/replaces this host's
# restricted key, opens its ufw port, and (re)installs the cron monitor.
set -eu

HOST="${1:?usage: ./egress/register-openco3.sh <hostname>  (matching egress/hosts/<hostname>.env)}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST_ENV="$REPO_DIR/egress/hosts/$HOST.env"
[ -f "$HOST_ENV" ] || { echo "✗ no $HOST_ENV"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "✗ run as root"; exit 1; }

# shellcheck disable=SC1090
. "$HOST_ENV"   # PORT, OPENCO3, PUBKEY
[ -n "${PUBKEY:-}" ] || { echo "✗ PUBKEY empty in $HOST_ENV — run install-egress.sh on the box first (2b), paste, commit"; exit 1; }

echo "== register egress host: $HOST → 172.18.0.1:$PORT =="

# 1. Landing zone: tunnel user + sshd drop-in (Phase 1) -------------------------
id tunnel >/dev/null 2>&1 || useradd -r -m -s /usr/sbin/nologin tunnel
install -d -m 700 -o tunnel -g tunnel /home/tunnel/.ssh

DROPIN=/etc/ssh/sshd_config.d/60-tunnel.conf
if [ ! -f "$DROPIN" ]; then
	cat > "$DROPIN" <<'EOF'
Match User tunnel
    GatewayPorts clientspecified
    AllowTcpForwarding remote
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
EOF
	sshd -t && systemctl reload ssh
fi

# 2. Authorized key, chained to this host's one port ----------------------------
AK=/home/tunnel/.ssh/authorized_keys
touch "$AK"; chown tunnel:tunnel "$AK"; chmod 600 "$AK"
LINE="restrict,port-forwarding,permitlisten=\"172.18.0.1:$PORT\" $PUBKEY $HOST"
# replace any previous line for this host (idempotent), then append the current one
grep -v " $HOST\$" "$AK" > "$AK.tmp" || true
mv "$AK.tmp" "$AK"; chown tunnel:tunnel "$AK"; chmod 600 "$AK"
echo "$LINE" >> "$AK"

# 3. Firewall: only docker containers may reach the tunnel port -----------------
ufw allow in on docker_gwbridge proto tcp from 172.18.0.0/16 to 172.18.0.1 port "$PORT" \
	comment "searxng egress socks ($HOST)" >/dev/null

# 4. Monitor: script + 5-min cron (Phase 7) -------------------------------------
install -m 755 "$REPO_DIR/egress/check-dark-search.sh" /usr/local/bin/check-dark-search
if [ ! -f /etc/dark-search-monitor.env ]; then
	echo "⚠ /etc/dark-search-monitor.env missing — write it once by hand:"
	echo '   echo NTFY_URL=https://ntfy.sh/<long-random-topic> > /etc/dark-search-monitor.env && chmod 600 /etc/dark-search-monitor.env'
fi
CRON="*/5 * * * * root /usr/local/bin/check-dark-search"
grep -qsF "$CRON" /etc/cron.d/dark-search-monitor 2>/dev/null \
	|| printf '%s\n' "$CRON" > /etc/cron.d/dark-search-monitor

echo "== done. Gate (run from openco3): =="
echo "   curl --socks5-hostname 172.18.0.1:$PORT -s https://api.ipify.org   # must print the BOX's IP"

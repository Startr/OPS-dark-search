#!/bin/sh
# install-egress.sh <hostname> — set up this machine as a dark-search egress proxy.
# Run ON the egress box (📦), from the repo clone, with sudo:
#   sudo ./egress/install-egress.sh home
# Idempotent: safe to re-run. Branches on `uname` → systemd (Linux) or launchd (macOS).
set -eu

HOST="${1:?usage: sudo ./egress/install-egress.sh <hostname>  (matching egress/hosts/<hostname>.env)}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST_ENV="$REPO_DIR/egress/hosts/$HOST.env"
[ -f "$HOST_ENV" ] || { echo "✗ no $HOST_ENV — declare the host in the repo first (2a)"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "✗ run with sudo (root is needed once, to install)"; exit 1; }

# shellcheck disable=SC1090
. "$HOST_ENV"   # PORT, OPENCO3
OS="$(uname)"

echo "== dark-search egress install: host=$HOST port=$PORT server=$OPENCO3 os=$OS =="

# 1. Packages ------------------------------------------------------------------
if [ "$OS" = "Linux" ]; then
	apt-get install -y microsocks autossh
else
	# brew refuses to run as root — run it as the invoking user.
	su - "${SUDO_USER:?need sudo, not a root login}" -c "brew list microsocks >/dev/null 2>&1 || brew install microsocks"
	su - "$SUDO_USER" -c "brew list autossh >/dev/null 2>&1 || brew install autossh"
fi

# 2. Service account (no-login) — runs the tunnel; never root ------------------
if [ "$OS" = "Linux" ]; then
	id egress >/dev/null 2>&1 || useradd -r -m -d /var/lib/egress -s /usr/sbin/nologin egress
	EGRESS_USER=egress
else
	if ! dscl . -read /Users/_egress >/dev/null 2>&1; then
		sysadminctl -addUser _egress -roleAccount -fullName "OpenCo Egress" -UID 492 -shell /usr/bin/false
	fi
	EGRESS_USER=_egress
fi

# 3. /etc/tunnel — env, key, known_hosts; owned by the service account ---------
install -d -m 750 /etc/tunnel
printf 'PORT=%s\nOPENCO3=%s\n' "$PORT" "$OPENCO3" > /etc/tunnel/tunnel.env
[ -f /etc/tunnel/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /etc/tunnel/id_ed25519 -C "$HOST-egress"
touch /etc/tunnel/known_hosts
chown -R "$EGRESS_USER" /etc/tunnel
chmod 600 /etc/tunnel/id_ed25519

# 4. Supervisor ------------------------------------------------------------------
if [ "$OS" = "Linux" ]; then
	cp "$REPO_DIR/egress/systemd/openco-microsocks.service" \
	   "$REPO_DIR/egress/systemd/openco-egress-tunnel.service" /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now openco-microsocks openco-egress-tunnel
	systemctl restart openco-egress-tunnel   # pick up env changes on re-runs
else
	cp "$REPO_DIR/egress/launchd/com.openco.microsocks.plist" \
	   "$REPO_DIR/egress/launchd/com.openco.egress-tunnel.plist" /Library/LaunchDaemons/
	chown root:wheel /Library/LaunchDaemons/com.openco.*.plist
	chmod 644 /Library/LaunchDaemons/com.openco.*.plist
	for svc in com.openco.microsocks com.openco.egress-tunnel; do
		launchctl bootout system "/Library/LaunchDaemons/$svc.plist" 2>/dev/null || true
		launchctl bootstrap system "/Library/LaunchDaemons/$svc.plist"
	done
	# A sleeping Mac is a dead tunnel: machine never sleeps, screen may.
	pmset -a sleep 0 displaysleep 5
fi

# 5. Hand-off --------------------------------------------------------------------
echo ""
echo "== done. Paste this pubkey into egress/hosts/$HOST.env (PUBKEY=\"...\") and commit 🗂 =="
cat /etc/tunnel/id_ed25519.pub
echo ""
echo "Then on openco3 ☁️ : ./egress/register-openco3.sh $HOST"

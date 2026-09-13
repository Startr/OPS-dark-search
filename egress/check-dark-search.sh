#!/bin/sh
# check-dark-search — 5-minute smoke detector for the egress tunnel + SearXNG.
# Installed to /usr/local/bin/check-dark-search by register-openco3.sh.
# Alerts once per state CHANGE (broken→fixed, fixed→broken) via ntfy — never spams.
#
# NTFY_URL (e.g. https://ntfy.sh/openco-dark-search-x7Rq2v) is a secret — this script
# is in git, so the topic lives in /etc/dark-search-monitor.env, written once by hand.
. /etc/dark-search-monitor.env
STATE=/var/tmp/dark-search.state; FAIL=""
DATACENTER_IP=199.241.136.186

IP=$(curl -m 8 -s --socks5-hostname 172.18.0.1:1080 https://api.ipify.org || true)
[ -n "$IP" ] && [ "$IP" != "$DATACENTER_IP" ] || FAIL="tunnel down (egress=$IP)"
curl -m 8 -sf https://dark-search.production.openco.ca/healthz >/dev/null || FAIL="$FAIL; searxng unhealthy"

PREV=$(cat $STATE 2>/dev/null || true)
[ "$FAIL" = "$PREV" ] || curl -m 8 -s -d "dark-search: ${FAIL:-recovered}" "$NTFY_URL" >/dev/null
printf '%s' "$FAIL" > $STATE

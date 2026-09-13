# OPS-dark-search

Infrastructure-as-code for **dark-search** (SearXNG on openco3/CapRover) and its
residential egress fleet. Why this exists, how it works, and the full teaching
runbook: see the plan in the team docs ("Fix CAPTCHA-blocked SearXNG via home
egress proxy").

## What's here

- `Dockerfile` — official SearXNG (pinned tag) + our two config files baked in.
- `searxng/settings.yml` — minimal overlay (`use_default_settings: true`): humane
  suspension times, fallback engines (mojeek/qwant), per-engine SOCKS5 proxies.
- `searxng/limiter.toml` — tiered access: public IPs get stock limits, in-swarm
  callers and the tailnet pass free.
- `egress/` — the proxy fleet: one `hosts/<name>.env` per box, systemd units +
  launchd plists, and three idempotent scripts (`install-egress.sh` on the box,
  `register-openco3.sh` on the server, `check-dark-search.sh` cron monitor).

## Adding an egress proxy (same three moves every time)

1. 🗂 REPO — add `egress/hosts/<name>.env` (next free PORT) + one `socks5h://` line
   in `searxng/settings.yml`; commit.
2. 📦 BOX — `sudo ./egress/install-egress.sh <name>`; paste printed pubkey into the
   `.env`; commit.
3. ☁️ SERVER — `./egress/register-openco3.sh <name>`, then `make deploy`.

`make deploy` runs `check-upstream` (pinned vs newest SearXNG tag) and
`check-proxies` (hosts ↔ proxy lines, one-to-one) before shipping.

## shared-valkey DB-index registry

Claim an index here **before** using it — two apps must never share one.

| index | app         | purpose                |
|-------|-------------|------------------------|
| 0     | dark-search | limiter / botdetection |
| 1–15  | free        | claim here first       |

## Secrets (never in git)

- `SEARXNG_SECRET`, `SEARXNG_VALKEY_URL`, `SEARXNG_LIMITER` — CapRover env vars.
- `NTFY_URL` — `/etc/dark-search-monitor.env` on openco3.
- Tunnel private keys — generated on each box in `/etc/tunnel/`, never leave it.

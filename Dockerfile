FROM searxng/searxng:2026.9.13-e61d09756
COPY searxng/settings.yml searxng/limiter.toml /etc/searxng/

FROM searxng/searxng:2026.9.12-87bf8c86e
COPY searxng/settings.yml searxng/limiter.toml /etc/searxng/

FROM node:24.11.1-bookworm-slim AS node

FROM elixir:1.19.5-otp-28-slim

COPY --from=node /usr/local/ /usr/local/

ENV CODEX_HOME=/var/lib/codex \
    MIX_ENV=prod \
    npm_config_cache=/pnpm/npm-cache \
    npm_config_store_dir=/pnpm/store \
    PNPM_HOME=/pnpm

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash bubblewrap build-essential ca-certificates curl git passwd \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/local/bin/pnpm \
    && npm install --global pnpm@12.15.0 @openai/codex@0.172.0

WORKDIR /app

COPY elixir/ /app/
COPY deploy/WORKFLOW.md /app/WORKFLOW.md
COPY deploy/codex-config.toml /etc/codex/config.toml
COPY deploy/requirements.toml /etc/codex/requirements.toml
COPY deploy/entrypoint.sh /usr/local/bin/symphony-entrypoint

RUN chmod 0755 /usr/local/bin/symphony-entrypoint \
    && mix deps.get --only prod \
    && mix compile \
    && mix escript.build \
    && groupadd --gid 1000 symphony \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/symphony --shell /bin/sh symphony \
    && mkdir -p /var/lib/codex /workspaces /pnpm \
    && chown -R 1000:1000 /var/lib/codex /workspaces /pnpm /home/symphony

USER 1000:1000

EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/symphony-entrypoint"]

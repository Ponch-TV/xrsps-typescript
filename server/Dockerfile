# Game server image.
#
# Build context is the REPO ROOT, not server/ — the server imports shared cache
# and protocol code from ../client (see server/tsconfig.json "include").
#
#   docker build -f server/Dockerfile -t xrsps-server .
#
# Runs TypeScript directly through tsx; there is no compile step. Only the
# packages the server actually imports at runtime need to be installed, which is
# why client/node_modules is not required here (`yarn typecheck` does need it,
# but that runs in CI, not in this image).
FROM node:22-bookworm-slim

# tini reaps zombies and forwards SIGTERM, so the server's graceful-shutdown
# handler runs and player state is flushed on `docker stop`.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first so code edits don't invalidate the install layer.
COPY server/package.json server/yarn.lock ./server/
RUN cd server && yarn install --frozen-lockfile && yarn cache clean

# Shared code pulled in from the client package. Keep this list in sync with
# the imports in server/src — currently common/, rs/ and custom/.
COPY client/common ./client/common
COPY client/rs ./client/rs
COPY client/custom ./client/custom

COPY server ./server

RUN chmod +x server/docker-entrypoint.sh

# caches/  — OSRS cache downloaded from OpenRS2 (~195MB)
# cache/   — precomputed collision data (~270MB)
# data/    — SQLite player state, accounts, trade escrow
#
# All three are declared as volumes so a container rebuild does not throw away
# the cache build (which takes minutes) or, more importantly, player saves.
VOLUME ["/app/server/caches", "/app/server/cache", "/app/server/data"]

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=43594

EXPOSE 43594

HEALTHCHECK --interval=30s --timeout=5s --start-period=15m --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||43594)+'/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/app/server/docker-entrypoint.sh"]

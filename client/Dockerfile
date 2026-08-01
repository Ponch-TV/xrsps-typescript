# Static client bundle, served by Caddy.
#
# Build context is the REPO ROOT (same as server/Dockerfile):
#
#   docker build -f client/Dockerfile --build-arg GAME_DOMAIN=game.example.com -t xrsps-client .
#
# Create React App inlines REACT_APP_* at build time, so the game's hostname is
# baked in here rather than configured at runtime. Serving the client from the
# same origin as the game server means the cache URL needs no configuration at
# all — the client's built-in `/caches/` default resolves correctly.

FROM node:22-bookworm-slim AS build

WORKDIR /app

COPY client/package.json client/yarn.lock ./client/
RUN cd client && yarn install --frozen-lockfile

COPY client ./client

ARG GAME_DOMAIN
ARG SERVER_NAME=xRSPS

# The quotes inside REACT_APP_SERVERS_JSON must be backslash-escaped: Docker
# strips unescaped ones from an ENV value, which yields invalid JSON and a
# silently empty server list.
ENV REACT_APP_DEFAULT_WS_URL=wss://${GAME_DOMAIN} \
    REACT_APP_DEFAULT_SERVER_ADDRESS=${GAME_DOMAIN} \
    REACT_APP_DEFAULT_SERVER_SECURE=true \
    REACT_APP_DEFAULT_SERVER_NAME=${SERVER_NAME} \
    REACT_APP_SERVERS_JSON="[{\"name\":\"${SERVER_NAME}\",\"address\":\"${GAME_DOMAIN}\",\"secure\":true,\"maxPlayers\":2047}]"

# CI=false: CRA treats warnings as errors under CI, and this tree has warnings.
# Webpack needs more heap than the default for a bundle this size.
RUN cd client && CI=false NODE_OPTIONS=--max-old-space-size=4096 yarn build

FROM caddy:2-alpine
COPY --from=build /app/client/build /srv/client

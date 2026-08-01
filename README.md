# XRSPS

A community-driven project inspired by Project Zanaris.
OSRS in the browser with a React/WebGL client and TypeScript WebSocket server.

## Packages

This repository root contains only:

- [`client/`](client/) — `@xrsps/client` (browser app)
- [`server/`](server/) — `@xrsps/server` (game server)
- [`docs/`](docs/) — documentation site

## Quick Start

Requires **Node.js v22.16+** and **Yarn**.

```bash
# Server
cd server
yarn install
yarn build-collision
yarn start

# Client (separate terminal)
cd client
yarn install
yarn start

# Docs (optional)
cd docs
yarn install
yarn dev
```

See [docs/setup.md](docs/setup.md) for details.

## Deploying

The client is a static bundle; the game server is a long-lived WebSocket process
that also serves the OSRS cache to players. To put both on the internet:

```bash
cp .env.deploy.example .env.deploy   # set GAME_DOMAIN + TLS_EMAIL
docker compose --env-file .env.deploy up -d --build
```

See [docs/deploy.md](docs/deploy.md) — includes an Oracle Cloud Always Free walkthrough.

---

Fan project. Not affiliated with, endorsed by, or connected to Jagex Ltd.
Old School RuneScape and related assets/trademarks belong to their respective owners.

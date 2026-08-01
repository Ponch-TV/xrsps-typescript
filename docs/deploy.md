# Deployment Guide

xRSPS is two pieces: a **static client** (React/WebGL bundle, ~24MB) and a
**game server** (long-lived Node process on a 600ms tick, WebSocket). The server
also serves the **OSRS cache** — ~195MB every new player downloads once.

The Compose stack in this repo puts all of it behind one hostname:

| URL                    | Served by                               |
| ---------------------- | --------------------------------------- |
| `https://HOST/`        | the game client                         |
| `wss://HOST/`          | game protocol                           |
| `https://HOST/caches/` | OSRS cache download                     |
| `https://HOST/status`  | player count, shown on the login screen |

One hostname means one certificate and no CORS to configure. You can host the
client separately instead — see [Hosting the client elsewhere](#hosting-the-client-elsewhere).

> **TLS is required, not optional.** Browsers refuse a plaintext `ws://`
> connection from an HTTPS page, so the game server has to be reachable over
> `wss://` — which means a real domain and a certificate. Caddy handles both.

---

## Sizing

The server holds the cache, collision data and world state in memory.

| Resource | Needs                                                                                |
| -------- | ------------------------------------------------------------------------------------ |
| RAM      | **~800MB idle with zero players.** Give it 2GB+.                                     |
| Disk     | ~500MB (195MB cache + 270MB collision) plus player saves.                            |
| CPU      | 1 core is enough to boot; 2+ keeps the tick comfortable.                             |
| Build    | The client bundle needs ~4GB RAM to compile. Building on the box is fine on A1.Flex. |

## Oracle Cloud (Always Free)

Oracle's free tier works well, with one important caveat about which shape you pick.

### The short version

Two things must happen in the Oracle web console — nothing outside your tenancy
can do them for you:

1. Create the instance as **VM.Standard.A1.Flex** (see [below](#pick-the-right-shape))
2. Add VCN ingress rules for **TCP 80 and 443** (see [below](#open-the-firewall-both-of-them))

Then point a domain at the instance's public IP and, over SSH, run:

```bash
curl -fsSL https://raw.githubusercontent.com/Ponch-TV/xrsps-typescript/claude/osrs-wow-conversion-60s94z/scripts/bootstrap-oracle.sh \
    | bash -s -- game.example.com you@example.com
```

That opens the instance's local firewall, installs Docker, clones the repo,
writes `.env.deploy`, builds, and waits until the server reports ready. It
refuses to start on the 1GB shape and tells you if DNS is not pointing here yet.
Re-running it is safe.

The rest of this section is what that script does, in case you would rather do
it by hand or something goes wrong.

### Pick the right shape

| Shape                   | Free tier            | Verdict                                    |
| ----------------------- | -------------------- | ------------------------------------------ |
| **VM.Standard.A1.Flex** | 4 OCPU / 24GB / ARM  | **Use this.** Enormous headroom.           |
| VM.Standard.E2.1.Micro  | 1/8 OCPU / 1GB / AMD | Too small — the server alone needs ~800MB. |

A1.Flex is **ARM (aarch64)**. That is fine here: the base image is multi-arch and
every dependency is pure JavaScript or WASM, so nothing needs to compile.

Create the instance with Ubuntu 22.04+ or Oracle Linux 9, at least 2 OCPU and 8GB
of the free A1 allocation, and the default 47GB boot volume.

### Open the firewall — both of them

This is the step that catches everyone. Oracle filters traffic in **two** places
and opening only one leaves the port looking dead from outside.

**1. The virtual network (in the Oracle console).** Networking → your VCN →
Subnet → Security List → Add Ingress Rules:

| Source    | Protocol | Destination port |
| --------- | -------- | ---------------- |
| 0.0.0.0/0 | TCP      | 80               |
| 0.0.0.0/0 | TCP      | 443              |

Port 80 is required — Let's Encrypt validates over it before issuing the cert.

**2. The instance's own firewall (over SSH).** Oracle images ship with
restrictive local rules regardless of what the VCN allows.

Ubuntu:

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

Oracle Linux:

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

### Point a domain at it

Add an **A record** for the hostname you want (say `game.example.com`) pointing
at the instance's public IP. It has to resolve publicly _before_ you start the
stack, because Caddy requests the certificate on first boot.

No domain? A free subdomain from DuckDNS or similar works fine — Caddy only
needs a name that resolves and answers on port 80.

### Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker
```

### Deploy

```bash
git clone https://github.com/Ponch-TV/xrsps-typescript.git
cd xrsps-typescript

cp .env.deploy.example .env.deploy
$EDITOR .env.deploy          # set GAME_DOMAIN and TLS_EMAIL

docker compose --env-file .env.deploy up -d --build
```

**First boot takes 10–20 minutes.** It compiles the client bundle, downloads the
OSRS cache, and builds collision data for 2,869 map regions into Docker volumes.
Watch it:

```bash
docker compose --env-file .env.deploy logs -f game
```

Wait for `WS listening on ws://0.0.0.0:43594`. Restarts after that are immediate
— the volumes persist both the cache and the collision build.

### Verify

```bash
curl https://game.example.com/status
# {"serverName":"xRSPS","playerCount":0,"maxPlayers":2047}

curl -sI https://game.example.com/caches/caches.json
# HTTP/2 200 ... access-control-allow-origin: *
```

If `/status` answers, `wss://` will work — same port, same certificate. Then open
`https://game.example.com` and log in. The first visit downloads the ~195MB cache
into browser storage; later visits skip it.

Log in with any username and a password of 8–20 characters. The first successful
login registers that username.

---

## Hosting the client elsewhere

Serving the client from the same box needs no configuration: the client's
built-in `/caches/` default already resolves to the game server.

To put the client on a CDN instead, it needs to be told where the game lives.
Create React App inlines `REACT_APP_*` **at build time**, so each of these
requires a rebuild, not just a restart.

| Variable                           | Value                              |
| ---------------------------------- | ---------------------------------- |
| `REACT_APP_DEFAULT_WS_URL`         | `wss://game.example.com`           |
| `REACT_APP_CACHE_BASE_URL`         | `https://game.example.com/caches/` |
| `REACT_APP_DEFAULT_SERVER_ADDRESS` | `game.example.com`                 |
| `REACT_APP_DEFAULT_SERVER_NAME`    | `xRSPS`                            |
| `REACT_APP_DEFAULT_SERVER_SECURE`  | `true`                             |

Cross-origin is fine — the cache endpoint sends `Access-Control-Allow-Origin: *`
and supports the range requests the resumable download needs.

### Vercel

The repo root `vercel.json` already points the build at `client/`. Import the
repo, set the variables above in Project → Settings → Environment Variables, and
deploy. Every push to the production branch rebuilds.

### Anywhere else

```bash
cd client
REACT_APP_DEFAULT_WS_URL=wss://game.example.com \
REACT_APP_CACHE_BASE_URL=https://game.example.com/caches/ \
CI=false yarn build
```

Serve the resulting `client/build/` as a static site with an SPA fallback
rewriting unknown paths to `/index.html`.

If you go this route the `caddy` service still works — it just serves a copy of
the client nobody visits. Point your CDN's variables at the same `GAME_DOMAIN`.

---

## Operations

```bash
docker compose --env-file .env.deploy logs -f game   # follow logs
docker compose --env-file .env.deploy restart game   # restart (saves flush first)
docker compose --env-file .env.deploy up -d --build  # deploy new code
```

Player state lives in the `player-data` volume as SQLite. Back it up:

```bash
docker run --rm -v xrsps-typescript_player-data:/data -v "$PWD:/out" \
    alpine tar czf /out/player-data-backup.tar.gz -C /data .
```

Once your characters exist, set `ALLOW_ACCOUNT_REGISTRATION=false` in
`.env.deploy` and restart so nobody else can claim usernames on your server.

### Troubleshooting

**Client sticks at "Loading data".** It cannot reach the cache. Check
`REACT_APP_CACHE_BASE_URL` resolves and returns `access-control-allow-origin: *`.

**Login screen shows the server offline.** The `/status` request failed — usually
a firewall rule missing on one of Oracle's two layers.

**Certificate never issues.** Port 80 must be open and the A record must resolve
to this box. `docker compose logs caddy` states the reason.

**Container is killed during first boot.** Out of memory during the collision
build — you are on the 1GB micro shape. Move to A1.Flex.

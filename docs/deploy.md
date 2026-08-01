# Deployment Guide

Running xRSPS for real means two separate things:

| Piece           | What it is                                     | Where it goes                       |
| --------------- | ---------------------------------------------- | ----------------------------------- |
| **Client**      | Static React/WebGL bundle, a few MB            | Any static host (Vercel, Pages, S3) |
| **Game server** | Long-lived Node process, 600ms tick, WebSocket | A VPS or container host             |

The game server also serves the **OSRS cache** (~195MB) over HTTP at `/caches/`,
so players downloading the cache and players connecting to the world hit the
same hostname. That keeps the deployment to one box and one certificate.

> The client is served over HTTPS, and browsers refuse a plaintext `ws://`
> connection from an HTTPS page. The game server **must** be reachable over
> `wss://`, which means a real domain and a certificate. The Compose stack below
> handles that with Caddy.

---

## Sizing

The server holds the cache, collision data and world state in memory.

| Resource | Needs                                                     |
| -------- | --------------------------------------------------------- |
| RAM      | **~800MB idle with zero players.** Give it 2GB+.          |
| Disk     | ~500MB (195MB cache + 270MB collision) plus player saves. |
| CPU      | 1 core is enough to boot; 2+ keeps the tick comfortable.  |

## Oracle Cloud (Always Free)

Oracle's free tier works well, with one important caveat about which shape you pick.

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

**First boot takes 10–20 minutes.** The container downloads the OSRS cache and
builds collision data for 2,869 map regions into Docker volumes. Watch it:

```bash
docker compose logs -f game
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

If `/status` answers, `wss://` will work — same port, same certificate.

---

## Client

The client reads its server and cache locations from build-time `REACT_APP_*`
variables. Create React App inlines these **at build time**, so changing one
requires a rebuild, not just a restart.

| Variable                           | Value                              |
| ---------------------------------- | ---------------------------------- |
| `REACT_APP_DEFAULT_WS_URL`         | `wss://game.example.com`           |
| `REACT_APP_CACHE_BASE_URL`         | `https://game.example.com/caches/` |
| `REACT_APP_DEFAULT_SERVER_ADDRESS` | `game.example.com`                 |
| `REACT_APP_DEFAULT_SERVER_NAME`    | `xRSPS`                            |
| `REACT_APP_DEFAULT_SERVER_SECURE`  | `true`                             |

### Vercel

The repo root `vercel.json` already points the build at `client/`. Set the
variables above in Project → Settings → Environment Variables, then deploy.
Every push to the production branch rebuilds.

### Anywhere else

```bash
cd client
REACT_APP_DEFAULT_WS_URL=wss://game.example.com \
REACT_APP_CACHE_BASE_URL=https://game.example.com/caches/ \
CI=false yarn build
```

Serve the resulting `client/build/` as a static site with an SPA fallback
rewriting unknown paths to `/index.html`.

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

#!/usr/bin/env bash
#
# One-shot deploy for a fresh Oracle Cloud (or any Debian/RHEL) VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/Ponch-TV/xrsps-typescript/claude/osrs-wow-conversion-60s94z/scripts/bootstrap-oracle.sh \
#       | bash -s -- game.example.com you@example.com
#
# Opens the instance firewall, installs Docker, clones the repo, and brings the
# stack up. Safe to re-run: every step checks before acting.
#
# Two things this cannot do for you, because they live in the Oracle web console:
#   1. Create the instance (use the VM.Standard.A1.Flex shape — see below)
#   2. Add VCN ingress rules for TCP 80 and 443
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Ponch-TV/xrsps-typescript.git}"
REPO_BRANCH="${REPO_BRANCH:-claude/osrs-wow-conversion-60s94z}"
CLONE_DIR="${CLONE_DIR:-$HOME/xrsps-typescript}"

GAME_DOMAIN="${1:-${GAME_DOMAIN:-}}"
TLS_EMAIL="${2:-${TLS_EMAIL:-}}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die() {
    printf '\033[31m  x %s\033[0m\n' "$*" >&2
    exit 1
}
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -n "$GAME_DOMAIN" ] || die "usage: bootstrap-oracle.sh <domain> [tls-email]"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die "need root or sudo"
    SUDO="sudo"
fi

# ---------------------------------------------------------------- preflight --

step "Checking this machine"

ARCH="$(uname -m)"
info "arch: $ARCH"
case "$ARCH" in
x86_64 | aarch64 | arm64) ;;
*) die "unsupported architecture: $ARCH" ;;
esac

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
info "memory: ${MEM_MB}MB"
if [ "$MEM_MB" -lt 1800 ]; then
    die "only ${MEM_MB}MB RAM. The game server alone idles at ~800MB and the client
     build needs ~4GB. You are on Oracle's 1GB micro shape — recreate the
     instance as VM.Standard.A1.Flex (Always Free, up to 4 OCPU / 24GB)."
elif [ "$MEM_MB" -lt 5000 ]; then
    warn "${MEM_MB}MB is enough to run but tight for the client build."
    warn "If the build gets OOM-killed, add swap or raise the A1.Flex allocation."
fi

DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
info "free disk: ${DISK_MB}MB"
[ "$DISK_MB" -gt 8000 ] || die "need at least ~8GB free, have ${DISK_MB}MB"

# ------------------------------------------------------------------- docker --

step "Installing Docker"

if command -v docker >/dev/null 2>&1; then
    info "already installed: $(docker --version)"
else
    curl -fsSL https://get.docker.com | $SUDO sh
    info "installed: $(docker --version)"
fi

$SUDO systemctl enable --now docker >/dev/null 2>&1 || true

# Group membership does not apply to an already-running shell, so decide once
# here whether this script needs sudo for docker and stick with it.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    DOCKER="$SUDO docker"
    $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || true
    info "using sudo for docker (log out and back in to drop the sudo)"
fi

$DOCKER compose version >/dev/null 2>&1 || die "docker compose plugin missing"

# ----------------------------------------------------------------- firewall --

step "Opening the instance firewall (80, 443)"

# Oracle images ship with restrictive local rules that block the ports even when
# the VCN security list allows them. This is the half people miss.
if command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    for port in 80 443; do
        $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    done
    $SUDO firewall-cmd --reload >/dev/null
    info "firewalld: 80/tcp and 443/tcp permitted"
elif command -v iptables >/dev/null 2>&1; then
    for port in 80 443; do
        if $SUDO iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            info "iptables: ${port}/tcp already allowed"
        else
            # Insert above Oracle's catch-all REJECT rather than appending after it.
            $SUDO iptables -I INPUT 1 -m state --state NEW -p tcp --dport "$port" -j ACCEPT
            info "iptables: ${port}/tcp allowed"
        fi
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
        $SUDO netfilter-persistent save >/dev/null 2>&1 && info "iptables rules persisted"
    elif [ -d /etc/iptables ]; then
        $SUDO sh -c 'iptables-save > /etc/iptables/rules.v4' && info "iptables rules persisted"
    else
        warn "could not persist iptables rules; they will vanish on reboot"
        warn "install iptables-persistent to keep them"
    fi
else
    warn "no firewalld or iptables found; assuming ports are already open"
fi

# ----------------------------------------------------------------------- dns --

step "Checking DNS for $GAME_DOMAIN"

PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"
# `getent hosts` exits non-zero for an unresolvable name, and under `pipefail`
# that would kill the script before it could explain why — which is exactly the
# state a first run is usually in.
RESOLVED="$(getent hosts "$GAME_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"

info "this box:  ${PUBLIC_IP:-unknown}"
info "$GAME_DOMAIN -> ${RESOLVED:-does not resolve}"

if [ -z "$RESOLVED" ]; then
    die "$GAME_DOMAIN does not resolve. Add an A record pointing at ${PUBLIC_IP:-this box}
     and re-run. Caddy requests the certificate on first boot, so DNS has to
     work first."
elif [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    warn "$GAME_DOMAIN points at $RESOLVED, not $PUBLIC_IP."
    warn "If that is a proxy (Cloudflare), set it to DNS-only or the cert will fail."
fi

# ---------------------------------------------------------------- checkout ---

step "Fetching the code"

if [ -d "$CLONE_DIR/.git" ]; then
    git -C "$CLONE_DIR" fetch origin "$REPO_BRANCH"
    git -C "$CLONE_DIR" checkout "$REPO_BRANCH"
    git -C "$CLONE_DIR" reset --hard "origin/$REPO_BRANCH"
    info "updated $CLONE_DIR"
else
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
    info "cloned to $CLONE_DIR"
fi

cd "$CLONE_DIR"

# ------------------------------------------------------------------ config ---

step "Writing .env.deploy"

if [ -f .env.deploy ]; then
    info "already exists, leaving it alone (delete it to regenerate)"
else
    cp .env.deploy.example .env.deploy
    # `|` as the separator so a domain never collides with the expression.
    sed -i "s|^GAME_DOMAIN=.*|GAME_DOMAIN=${GAME_DOMAIN}|" .env.deploy
    info "GAME_DOMAIN=$GAME_DOMAIN"
    if [ -n "$TLS_EMAIL" ]; then
        sed -i "s|^TLS_EMAIL=.*|TLS_EMAIL=${TLS_EMAIL}|" .env.deploy
        info "TLS_EMAIL=$TLS_EMAIL"
    else
        warn "no TLS email given; Let's Encrypt expiry warnings will go nowhere"
    fi
fi

# ---------------------------------------------------------------- bring up ---

step "Building and starting (first run takes 10-20 minutes)"

info "compiling the client, downloading the ~195MB OSRS cache, and building"
info "collision data for 2,869 map regions. Volumes keep all of it, so"
info "restarts after this are immediate."
echo

$DOCKER compose --env-file .env.deploy up -d --build

step "Waiting for the game server"

# The collision build dominates first boot; give it room before giving up.
DEADLINE=$((SECONDS + 2400))
READY=0
while [ $SECONDS -lt $DEADLINE ]; do
    if $DOCKER compose --env-file .env.deploy logs game 2>/dev/null | grep -q "WS listening"; then
        READY=1
        break
    fi
    # `ps -q` still lists a stopped container, so ask the container itself.
    GAME_CID="$($DOCKER compose --env-file .env.deploy ps -q game 2>/dev/null | head -1 || true)"
    if [ -n "$GAME_CID" ] &&
        [ "$($DOCKER inspect -f '{{.State.Running}}' "$GAME_CID" 2>/dev/null)" != "true" ]; then
        die "the game container stopped during startup. Logs:
     $DOCKER compose --env-file .env.deploy logs game"
    fi
    printf '.'
    sleep 15
done
echo

if [ "$READY" -ne 1 ]; then
    die "server did not report ready within 40 minutes. Check:
     $DOCKER compose --env-file .env.deploy logs -f game"
fi

bold "Game server is up."

step "Verifying from the outside"

sleep 5
STATUS="$(curl -fsS --max-time 30 "https://${GAME_DOMAIN}/status" 2>/dev/null || echo "")"
if [ -n "$STATUS" ]; then
    info "https://${GAME_DOMAIN}/status -> $STATUS"
    echo
    bold "Done. Open https://${GAME_DOMAIN} and log in."
    info "Any username, password 8-20 characters. First login registers it."
    info "The first visit downloads the ~195MB cache into browser storage."
else
    warn "could not reach https://${GAME_DOMAIN}/status from the box itself."
    echo
    warn "The server is running, so this is almost always the VCN security list —"
    warn "the half of Oracle's firewall that is not on this machine:"
    warn "  Networking -> your VCN -> Subnet -> Security List -> Add Ingress Rules"
    warn "  Source 0.0.0.0/0, TCP, destination ports 80 and 443"
    echo
    warn "Certificate trouble instead? Port 80 must be open for Let's Encrypt:"
    warn "  $DOCKER compose --env-file .env.deploy logs caddy"
fi

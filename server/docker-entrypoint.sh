#!/bin/sh
# Prepare the on-disk data the server needs, then hand off to it.
#
# Both steps are expensive and idempotent, so they run once against the mounted
# volumes and are skipped on every later boot. First start on a fresh volume
# takes roughly 10-20 minutes; restarts are immediate.
set -eu

cd /app/server

if [ ! -f caches/caches.json ]; then
    echo "[entrypoint] no OSRS cache found, downloading (~195MB)..."
    yarn --silent ensure-cache
else
    echo "[entrypoint] OSRS cache present"
fi

# 2869 regions get built. Treat a thin directory as an interrupted build and
# resume it — the builder skips regions it has already written.
collision_files=$(find cache/collision -name '*.bin' 2>/dev/null | head -2900 | wc -l)
if [ "$collision_files" -lt 2869 ]; then
    echo "[entrypoint] collision cache incomplete ($collision_files regions), building..."
    npx tsx scripts/build-collision-cache.ts --include-models
else
    echo "[entrypoint] collision cache present ($collision_files regions)"
fi

echo "[entrypoint] starting game server (gamemode=${GAMEMODE:-from config.json})"
exec npx tsx src/index.ts

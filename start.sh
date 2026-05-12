#!/usr/bin/env bash
# start.sh — OpenHost supervisor for Nitter (pitchforked).
#
# Manages two processes inside one container:
#   1. Redis   (127.0.0.1:6379, in-memory cache)
#   2. Nitter  (0.0.0.0:8080)
#
# Auth: no SSO proxy needed. Nitter has no user accounts — the
# OpenHost router's zone_auth cookie gates all access.
#
# Uses bash + wait -n for supervision.

set -euo pipefail

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/nitter}"
ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-nitter}"
NITTER_HOSTNAME="${APP_NAME}.${ZONE_DOMAIN}"

# ---------------------------------------------------------------------------
# 1. Prepare directories
# ---------------------------------------------------------------------------
mkdir -p "$APP_DATA"

NITTER_WORK="/opt/nitter"

# ---------------------------------------------------------------------------
# 2. HMAC key (generate once, persist)
# ---------------------------------------------------------------------------
HMAC_KEY_FILE="${APP_DATA}/.hmac_key"
if [ -f "$HMAC_KEY_FILE" ]; then
    HMAC_KEY=$(cat "$HMAC_KEY_FILE")
else
    HMAC_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    printf '%s' "$HMAC_KEY" > "$HMAC_KEY_FILE"
    chmod 600 "$HMAC_KEY_FILE"
fi

# ---------------------------------------------------------------------------
# 3. Sessions file (user provides Twitter cookies here)
#
# The pitchforked fork reads a JSONL file (one JSON object per line).
# Each line is either an OAuth session:
#   {"oauthToken": "...", "oauthTokenSecret": "..."}
# or a cookie session (browser cookies):
#   {"kind": "cookie", "authToken": "<auth_token>", "ct0": "<ct0>"}
#
# Migrate from the old guest_accounts.jsonl name if present.
# ---------------------------------------------------------------------------
SESSIONS_FILE="${APP_DATA}/sessions.jsonl"
OLD_SESSIONS_FILE="${APP_DATA}/guest_accounts.jsonl"

# Migrate old file name if new one doesn't exist yet
if [ ! -f "$SESSIONS_FILE" ] && [ -f "$OLD_SESSIONS_FILE" ] && [ -s "$OLD_SESSIONS_FILE" ]; then
    echo "[start.sh] Migrating guest_accounts.jsonl -> sessions.jsonl"
    mv "$OLD_SESSIONS_FILE" "$SESSIONS_FILE"
fi

if [ ! -f "$SESSIONS_FILE" ] || [ ! -s "$SESSIONS_FILE" ]; then
    cat > "$SESSIONS_FILE" <<'EOF'
EOF
    echo "[start.sh] WARNING: No Twitter session tokens found."
    echo "[start.sh] Create sessions.jsonl in the app data directory"
    echo "[start.sh] with one JSON object per line."
    echo "[start.sh]"
    echo "[start.sh] Cookie session (from browser dev-tools):"
    echo '[start.sh]   {"kind": "cookie", "authToken": "<auth_token>", "ct0": "<ct0>"}'
    echo "[start.sh]"
    echo "[start.sh] OAuth session:"
    echo '[start.sh]   {"oauthToken": "<token>", "oauthTokenSecret": "<secret>"}'
    echo "[start.sh]"
    echo "[start.sh] Upload via file-browser or SFTP."
fi

# Tell nitter where the sessions file lives
export NITTER_SESSIONS_FILE="$SESSIONS_FILE"

# ---------------------------------------------------------------------------
# 4. Generate nitter.conf
# ---------------------------------------------------------------------------

# Determine HTTPS setting from zone domain
case "$ZONE_DOMAIN" in
    lvh.me|*.lvh.me|localhost|*.localhost)
        NITTER_HTTPS="false"
        ;;
    *)
        NITTER_HTTPS="true"
        ;;
esac

cat > "${NITTER_WORK}/nitter.conf" <<NITTERCFG
[Server]
hostname = "${NITTER_HOSTNAME}"
title = "Nitter"
address = "0.0.0.0"
port = 8080
https = ${NITTER_HTTPS}
httpMaxConnections = 100
staticDir = "./public"

[Cache]
redisHost = "127.0.0.1"
redisPort = 6379
redisConnections = 20
listMinutes = 240
rssMinutes = 10

[Config]
hmacKey = "${HMAC_KEY}"
base64Media = false
enableRSS = true
enableDebug = false
proxy = ""
proxyAuth = ""
maxConcurrentReqs = 2

[Preferences]
theme = "Nitter"
replaceTwitter = ""
replaceYouTube = ""
replaceReddit = ""
proxyVideos = true
hlsPlayback = false
infiniteScroll = false
NITTERCFG

echo "[start.sh] Generated nitter.conf (hostname=${NITTER_HOSTNAME})"

# ---------------------------------------------------------------------------
# 5. Start Redis
# ---------------------------------------------------------------------------
echo "[start.sh] Starting Redis..."
redis-server \
    --daemonize no \
    --port 6379 \
    --bind 127.0.0.1 \
    --maxmemory 64mb \
    --maxmemory-policy allkeys-lru \
    --save "" \
    --loglevel warning &
REDIS_PID=$!

# Wait for Redis
for i in $(seq 1 30); do
    if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q PONG; then
        echo "[start.sh] Redis is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[start.sh] ERROR: Redis failed to start."
        exit 1
    fi
    sleep 0.5
done

# ---------------------------------------------------------------------------
# 6. Start Nitter
# ---------------------------------------------------------------------------
echo "[start.sh] Starting Nitter on 0.0.0.0:8080..."
cd "${NITTER_WORK}"
./nitter &
NITTER_PID=$!

# Wait for Nitter to start accepting connections
for i in $(seq 1 30); do
    if curl -sf -o /dev/null http://127.0.0.1:8080/ 2>/dev/null; then
        echo "[start.sh] Nitter is ready."
        break
    fi
    if ! kill -0 "$NITTER_PID" 2>/dev/null; then
        echo "[start.sh] ERROR: Nitter process exited during startup."
        exit 1
    fi
    if [ "$i" -eq 30 ]; then
        echo "[start.sh] WARNING: Nitter did not respond within 15s, continuing anyway."
    fi
    sleep 0.5
done

echo "[start.sh] All processes running (Redis=$REDIS_PID, Nitter=$NITTER_PID)"

# ---------------------------------------------------------------------------
# 7. Supervise — if any process exits, tear down and exit
# ---------------------------------------------------------------------------
cleanup() {
    echo "[start.sh] Shutting down..."
    kill "$NITTER_PID" "$REDIS_PID" 2>/dev/null || true
    wait
}
trap cleanup EXIT SIGTERM SIGINT

set +e
wait -n "$REDIS_PID" "$NITTER_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE). Shutting down."
exit "$EXIT_CODE"

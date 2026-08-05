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
# 5. Helpers: session detection + placeholder web server
# ---------------------------------------------------------------------------
#
# The prebuilt nitter binary SIGSEGVs (nil-session dereference) the moment it
# makes a Twitter API call with no usable session loaded. With an empty or
# all-expired sessions file that happens within seconds of startup, and the
# old supervisor exited on the crash — so the container was recreated and
# crashed again, forever (a restart storm).
#
# To avoid that, we only launch nitter when the sessions file looks usable,
# and we keep a tiny placeholder server answering :8080 (so the OpenHost
# health check on "/" passes and the container stays stable) whenever nitter
# can't run. nitter auto-starts within ~10s of a usable sessions file
# appearing.

# A session file is "usable" if it has at least one line carrying a session
# credential key. Cheap structural check (no jq): it does NOT prove the tokens
# still work with Twitter, only that the file is worth handing to nitter.
has_usable_sessions() {
    [ -s "$SESSIONS_FILE" ] || return 1
    grep -qE '"(authToken|oauthToken)"[[:space:]]*:' "$SESSIONS_FILE"
}

sessions_mtime() {
    stat -c %Y "$SESSIONS_FILE" 2>/dev/null || echo 0
}

PLACEHOLDER_PID=""
start_placeholder() {
    # Already running? Leave it.
    if [ -n "$PLACEHOLDER_PID" ] && kill -0 "$PLACEHOLDER_PID" 2>/dev/null; then
        return 0
    fi
    mkdir -p /tmp/placeholder
    cat > /tmp/placeholder/index.html <<'HTML'
<!doctype html>
<title>Nitter — waiting for session tokens</title>
<body style="font-family:system-ui,sans-serif;max-width:40em;margin:4em auto;padding:0 1em;line-height:1.5">
<h1>Nitter is waiting for Twitter/X session tokens</h1>
<p>Nitter cannot serve tweets without at least one valid session, and the
prebuilt binary crashes if it tries. To avoid a crash-loop, this placeholder
is running instead.</p>
<p>Add one JSON object per line to
<code>/data/app_data/nitter/sessions.jsonl</code> — for example a browser-cookie
session:</p>
<pre>{"kind": "cookie", "authToken": "&lt;auth_token&gt;", "ct0": "&lt;ct0&gt;"}</pre>
<p>Nitter starts automatically within ~10&nbsp;seconds of the file being
updated with a usable session.</p>
</body>
HTML
    # busybox httpd stays listening on :8080 and serves index.html for "/",
    # so the health check passes. Run foreground, backgrounded by the script
    # so we get a stable PID to manage.
    busybox-extras httpd -f -p 8080 -h /tmp/placeholder &
    PLACEHOLDER_PID=$!
    echo "[start.sh] Placeholder web server running on :8080 (PID=$PLACEHOLDER_PID)."
}
stop_placeholder() {
    if [ -n "$PLACEHOLDER_PID" ] && kill -0 "$PLACEHOLDER_PID" 2>/dev/null; then
        kill "$PLACEHOLDER_PID" 2>/dev/null || true
        wait "$PLACEHOLDER_PID" 2>/dev/null || true
    fi
    PLACEHOLDER_PID=""
}

# Serve the placeholder and block until the operator writes a usable session
# file. We require the mtime to CHANGE since we started waiting, so a
# crash-loop caused by *expired* tokens (file already "usable"-looking) waits
# for a real update instead of instantly relaunching into another segfault.
wait_for_sessions() {
    local baseline
    baseline="$(sessions_mtime)"
    start_placeholder
    echo "[start.sh] Waiting for a usable sessions.jsonl (polling every 10s)..."
    while true; do
        sleep 10
        if [ "$(sessions_mtime)" != "$baseline" ] && has_usable_sessions; then
            echo "[start.sh] Detected updated sessions.jsonl with a usable session."
            stop_placeholder
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# 6. Start Redis
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
# 7. Cleanup trap
# ---------------------------------------------------------------------------
NITTER_PID=""
cleanup() {
    echo "[start.sh] Shutting down..."
    kill "$NITTER_PID" "$PLACEHOLDER_PID" "$REDIS_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

# ---------------------------------------------------------------------------
# 8. Supervise Nitter with a crash-loop breaker
#
# Launch nitter only when there is a usable session file. If nitter keeps
# dying quickly (the segfault-on-nil-session signature of no/expired tokens),
# stop relaunching and fall back to the placeholder until the operator updates
# sessions.jsonl. Redis dying is treated as fatal. The container never exits
# on a nitter crash, so OpenHost never restart-storms it, and :8080 always
# answers the health check.
# ---------------------------------------------------------------------------
HEALTHY_UPTIME=60      # seconds nitter must survive to NOT count as a fast crash
MAX_RAPID_CRASHES=3    # consecutive fast crashes before falling back to placeholder
rapid_crashes=0

while true; do
    if ! has_usable_sessions; then
        echo "[start.sh] No usable Twitter sessions in ${SESSIONS_FILE}."
        wait_for_sessions
        rapid_crashes=0
    fi

    echo "[start.sh] Starting Nitter on 0.0.0.0:8080..."
    ( cd "${NITTER_WORK}" && exec ./nitter ) &
    NITTER_PID=$!
    started_at="$(date +%s)"
    echo "[start.sh] Nitter running (Redis=$REDIS_PID, Nitter=$NITTER_PID)."

    set +e
    wait -n "$REDIS_PID" "$NITTER_PID"
    set -e

    # Redis dying is fatal — no cache, no reason to stay up; let OpenHost recreate us.
    if ! kill -0 "$REDIS_PID" 2>/dev/null; then
        echo "[start.sh] ERROR: Redis exited. Shutting down."
        exit 1
    fi

    # Otherwise nitter is what exited.
    uptime=$(( $(date +%s) - started_at ))
    NITTER_PID=""
    echo "[start.sh] Nitter exited after ${uptime}s."

    if [ "$uptime" -lt "$HEALTHY_UPTIME" ]; then
        rapid_crashes=$(( rapid_crashes + 1 ))
    else
        rapid_crashes=0
    fi

    if [ "$rapid_crashes" -ge "$MAX_RAPID_CRASHES" ]; then
        echo "[start.sh] Nitter crashed ${rapid_crashes}x quickly — likely no valid sessions."
        echo "[start.sh] Serving placeholder until sessions.jsonl is updated."
        wait_for_sessions
        rapid_crashes=0
    else
        echo "[start.sh] Restarting Nitter (rapid_crashes=${rapid_crashes}/${MAX_RAPID_CRASHES})."
        sleep 2
    fi
done

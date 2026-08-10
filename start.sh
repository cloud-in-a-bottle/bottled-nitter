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

# Tell nitter where the sessions file lives. Also export SESSIONS_FILE so the
# placeholder's token-entry CGI (a child of this script via busybox httpd) knows
# where to append sessions.
export NITTER_SESSIONS_FILE="$SESSIONS_FILE"
export SESSIONS_FILE

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
    mkdir -p /tmp/placeholder/cgi-bin

    # The landing page is an owner-only form for pasting Twitter/X session
    # tokens. The whole app sits behind the OpenHost owner SSO, so only the
    # space owner can reach this. Submitting posts to the CGI below, which
    # appends the session to sessions.jsonl; wait_for_sessions() then picks it
    # up and launches nitter.
    cat > /tmp/placeholder/index.html <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nitter — add session tokens</title>
<style>
  body{font-family:system-ui,sans-serif;max-width:44em;margin:3em auto;padding:0 1.2em;line-height:1.55;color:#222;background:#fafafa}
  h1{font-size:1.4rem} code,pre{background:#eee;border-radius:4px;padding:.1em .35em;font-size:.9em}
  pre{padding:.7em;overflow:auto} label{display:block;margin:.9em 0 .25em;font-weight:600}
  input[type=text],textarea{width:100%;box-sizing:border-box;padding:.55em;border:1px solid #bbb;border-radius:6px;font-family:ui-monospace,monospace;font-size:.95em}
  button{margin-top:1.1em;padding:.6em 1.3em;border:0;border-radius:6px;background:#1d9bf0;color:#fff;font-size:1rem;cursor:pointer}
  .muted{color:#666;font-size:.9em} details{margin-top:1.4em} summary{cursor:pointer;font-weight:600}
  .card{background:#fff;border:1px solid #e3e3e3;border-radius:10px;padding:1.4em 1.6em}
</style></head>
<body>
<div class="card">
<h1>Nitter needs a Twitter/X session</h1>
<p>Nitter can't load tweets without at least one valid session. Add one below —
Nitter starts automatically within ~15&nbsp;seconds. This page is only reachable
by you (the space owner).</p>

<form method="post" action="/cgi-bin/save">
  <label for="authToken">auth_token cookie</label>
  <input id="authToken" name="authToken" type="text" autocomplete="off" spellcheck="false" placeholder="e.g. a1b2c3… (40 hex chars)">
  <label for="ct0">ct0 cookie</label>
  <input id="ct0" name="ct0" type="text" autocomplete="off" spellcheck="false" placeholder="e.g. 9f8e7d… (long hex string)">
  <button type="submit">Save &amp; start Nitter</button>
</form>

<p class="muted">Get these from a logged-in X.com browser tab: DevTools →
Application → Cookies → <code>https://x.com</code> → copy the
<code>auth_token</code> and <code>ct0</code> values. Use a throwaway account.</p>

<details>
  <summary>Advanced: paste raw sessions JSONL</summary>
  <form method="post" action="/cgi-bin/save">
    <p class="muted">One JSON object per line. Cookie or OAuth sessions:</p>
    <pre>{"kind":"cookie","authToken":"…","ct0":"…"}
{"oauthToken":"…","oauthTokenSecret":"…"}</pre>
    <textarea name="raw" rows="5" spellcheck="false" placeholder='{"kind":"cookie","authToken":"…","ct0":"…"}'></textarea>
    <button type="submit">Append lines &amp; start Nitter</button>
  </form>
</details>
</div>
</body></html>
HTML

    # CGI handler: validate + append submitted session(s) to sessions.jsonl.
    # SESSIONS_FILE is inherited from start.sh's exported env (with a fallback).
    cat > /tmp/placeholder/cgi-bin/save <<'CGI'
#!/bin/sh
SESSIONS_FILE="${SESSIONS_FILE:-/data/app_data/nitter/sessions.jsonl}"

printf 'Content-Type: text/html\r\n\r\n'

fail() {
    printf '<!doctype html><meta charset=utf-8><title>Error</title><body style="font-family:system-ui;max-width:40em;margin:3em auto"><h1>Could not save</h1><p>%s</p><p><a href="/">&larr; Back</a></p>' "$1"
    exit 0
}

[ "$REQUEST_METHOD" = "POST" ] || fail "Please use the form."

body=$(head -c "${CONTENT_LENGTH:-0}")

# urldecode: +->space, %XX->byte
urldec() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"; }
# first value for a form key
field() { printf '%s' "$body" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1; }

tmp=$(mktemp)
added=0

raw=$(field raw)
if [ -n "$raw" ]; then
    # Advanced path: accept only lines that look like a JSON object carrying a
    # session credential key. Lenient by design — has_usable_sessions and the
    # crash-breaker are the real safety net if a line is subtly malformed.
    # `|| [ -n "$line" ]` so a final line with no trailing newline isn't dropped.
    urldec "$raw" | tr -d '\r' | while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \{*\}) : ;;
            *) continue ;;
        esac
        case "$line" in
            *'"authToken"'*|*'"oauthToken"'*) printf '%s\n' "$line" >> "$tmp" ;;
        esac
    done
    added=$(grep -c . "$tmp" 2>/dev/null || echo 0)
else
    # Simple path: a cookie session from two fields. Strict character check so
    # the values can be safely embedded in JSON with no escaping or injection.
    authToken=$(urldec "$(field authToken)")
    ct0=$(urldec "$(field ct0)")
    okchars() { case "$1" in *[!A-Za-z0-9_-]*|"") return 1;; esac; return 0; }
    okchars "$authToken" || fail "auth_token is missing or has unexpected characters."
    okchars "$ct0" || fail "ct0 is missing or has unexpected characters."
    printf '{"kind":"cookie","authToken":"%s","ct0":"%s"}\n' "$authToken" "$ct0" >> "$tmp"
    added=1
fi

[ "$added" -ge 1 ] || fail "No usable session found in what you submitted."

# Make sure the existing file ends with a newline before we append.
if [ -s "$SESSIONS_FILE" ] && [ "$(tail -c1 "$SESSIONS_FILE" 2>/dev/null | wc -l)" -eq 0 ]; then
    printf '\n' >> "$SESSIONS_FILE"
fi
cat "$tmp" >> "$SESSIONS_FILE"
rm -f "$tmp"
chmod 600 "$SESSIONS_FILE" 2>/dev/null || true

printf '<!doctype html><meta charset=utf-8><meta http-equiv="refresh" content="15;url=/"><title>Saved</title><body style="font-family:system-ui;max-width:40em;margin:3em auto"><h1>Saved %s session(s)</h1><p>Nitter is starting &mdash; this page reloads in ~15&nbsp;seconds.</p><p><a href="/">Reload now</a></p>' "$added"
CGI
    chmod +x /tmp/placeholder/cgi-bin/save

    # busybox httpd stays listening on :8080, serves index.html for "/" (so the
    # health check passes) and runs the cgi-bin/ handler for POSTs. Run
    # foreground, backgrounded by the script so we get a stable PID to manage.
    busybox-extras httpd -f -p 8080 -h /tmp/placeholder &
    PLACEHOLDER_PID=$!
    echo "[start.sh] Placeholder web server running on :8080 (PID=$PLACEHOLDER_PID) — token-entry form available."
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

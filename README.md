# bottled-nitter

Nitter (privacy-respecting Twitter/X frontend) packaged for Cloud in a Bottle.

<img width="1111" height="801" alt="Screenshot 2026-08-25 at 4 06 09 PM" src="https://github.com/user-attachments/assets/02892fde-e261-4c53-8d3f-70da6ca73422" />

Uses the [sekai-soft/nitter](https://github.com/sekai-soft/nitter) fork which supports guest accounts and authenticated sessions.

## Auth Model

No SSO. All access is gated behind Cloud in a Bottle zone_auth. No public paths.

## Setup

After deploying, you must provide at least one Twitter/X session token for Nitter to function. The prebuilt binary crashes on any API call when it has no usable session, so until one is provided the app serves a token-entry page instead of crash-looping (see "Crash resilience" below).

### Option A — the token-entry page (easiest)

While Nitter has no usable session, opening the app in a browser shows a small form (owner-only, since the whole app is behind Cloud in a Bottle SSO). Paste the `auth_token` and `ct0` cookies from a logged-in X.com tab (DevTools → Application → Cookies → `https://x.com`) and submit. Nitter starts automatically within ~15 seconds. The form also has an "Advanced" box for pasting raw `sessions.jsonl` lines (cookie or OAuth).

### Option B — upload the file directly

Write one JSON object per line to `/data/app_data/nitter/sessions.jsonl` via file-browser or SFTP. `start.sh` picks up a usable file within ~10 seconds and launches Nitter.

```jsonl
{"kind": "cookie", "authToken": "<auth_token>", "ct0": "<ct0>"}
{"oauthToken": "<token>", "oauthTokenSecret": "<secret>"}
```

Use a throwaway account — these are full account credentials.

### Crash resilience

Sessions expire. When they do, Nitter segfaults on its next API call; `start.sh` detects the rapid crashes, stops relaunching, and falls back to the token-entry page so the container stays stable instead of restart-looping. Enter fresh tokens on that page (or update the file) and Nitter restarts automatically.

## Architecture

- Alpine base with Redis (for caching) and the Nitter binary copied from the upstream Docker image
- Redis runs in-process (no persistence, cache only)
- start.sh generates nitter.conf from Cloud in a Bottle environment variables
- HMAC key is generated once and persisted in app_data
- Listens on port 8080

## Resources

- Memory: 512 MB
- CPU: 250 millicores

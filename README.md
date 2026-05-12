# openhost-nitter

Nitter (privacy-respecting Twitter/X frontend) packaged for OpenHost.

Uses the [sekai-soft/nitter](https://github.com/sekai-soft/nitter) fork which supports guest accounts and authenticated sessions.

## Auth Model

No SSO. All access is gated behind OpenHost zone_auth. No public paths.

## Setup

After deploying, you must provide Twitter/X session tokens for Nitter to function.

### guest_accounts.jsonl

Nitter needs a `guest_accounts.jsonl` file containing Twitter API session tokens. Without it, Nitter will start but fail to load any tweets.

1. Generate session tokens following the [sekai-soft/nitter wiki](https://github.com/sekai-soft/nitter/wiki).
2. Upload `guest_accounts.jsonl` to the app's data directory via file-browser or SFTP.
   - The file goes in: `/data/app_data/nitter/guest_accounts.jsonl`
3. Restart the app (or it will pick up the file on next restart).

### Example guest_accounts.jsonl format

```jsonl
{"oauth_token":"...","oauth_token_secret":"..."}
{"oauth_token":"...","oauth_token_secret":"..."}
```

## Architecture

- Alpine base with Redis (for caching) and the Nitter binary copied from the upstream Docker image
- Redis runs in-process (no persistence, cache only)
- start.sh generates nitter.conf from OpenHost environment variables
- HMAC key is generated once and persisted in app_data
- Listens on port 8080

## Resources

- Memory: 512 MB
- CPU: 250 millicores

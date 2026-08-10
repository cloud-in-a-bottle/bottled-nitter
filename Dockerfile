# Nitter for OpenHost — privacy-respecting Twitter/X frontend.
#
# Single container running:
#   - Redis   (127.0.0.1:6379, loopback, in-memory cache)
#   - Nitter  (0.0.0.0:8080, externally routed)
#
# Auth: no SSO proxy needed — the OpenHost router's zone_auth
# cookie gates all access. Nitter has no user accounts.
#
# Uses the sekai-soft/nitter-pitchforked fork which supports both
# OAuth tokens and cookie-based (ct0/auth_token) sessions.

FROM ghcr.io/sekai-soft/nitter-pitchforked:latest AS nitter-src

FROM docker.io/library/alpine:3.20

RUN apk add --no-cache \
    bash \
    redis \
    tini \
    curl \
    ca-certificates \
    pcre \
    libssl3 \
    libcrypto3 \
    busybox-extras

# Copy the nitter binary and static assets from the upstream image.
# The pitchforked image has them at /src/.
COPY --from=nitter-src /src/nitter /opt/nitter/nitter
COPY --from=nitter-src /src/public /opt/nitter/public

COPY start.sh /opt/openhost/start.sh
RUN chmod 0755 /opt/openhost/start.sh

EXPOSE 8080

ENTRYPOINT ["tini", "--", "/opt/openhost/start.sh"]

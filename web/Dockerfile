# Combines: Quartz v4 build-watch loop + a stripped-down Caddy for static
# serving (no TLS/ACME — Nginx Proxy Manager fronts this), supervised by
# s6-overlay. Never mounts the vault; only ever reads /quartz/content,
# which the separate `stager` container fills.

FROM caddy:2 AS caddy-bin

FROM node:22-slim

ARG S6_OVERLAY_VERSION=3.2.0.2
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git inotify-tools rsync gettext-base ca-certificates curl xz-utils && \
    rm -rf /var/lib/apt/lists/*

# s6-overlay release tarballs use x86_64/aarch64; buildx's TARGETARCH is
# amd64/arm64 — map between the two so this builds on both platforms.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) S6ARCH=x86_64 ;; \
      arm64) S6ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/s6-noarch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL -o /tmp/s6-arch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6ARCH}.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz; \
    rm -f /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz

COPY --from=caddy-bin /usr/bin/caddy /usr/bin/caddy

WORKDIR /quartz
# Pinned to last stable Quartz v4 — matches upstream's own Dockerfile, which
# notes v5 (main) was broken at the time this reference stack was written.
# Re-check upstream before bumping.
RUN git clone --depth 1 --branch v4.5.2 https://github.com/jackyzha0/quartz.git . && \
    npm ci

COPY quartz.config.ts.template /quartz/quartz.config.ts.template
COPY quartz.layout.ts /quartz/quartz.layout.ts
COPY FolderSidebar.tsx /quartz/FolderSidebar.tsx
COPY entrypoint.sh /entrypoint.sh
COPY pf-find.js /pf-find.js
RUN chmod +x /entrypoint.sh

COPY Caddyfile /etc/caddy/Caddyfile
COPY s6-rc.d /etc/s6-overlay/s6-rc.d

EXPOSE 8080
ENTRYPOINT ["/init"]

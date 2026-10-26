FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 \
    GOOS="${TARGETOS:-linux}" \
    GOARCH="${TARGETARCH:-amd64}" \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/opencode2api ./cmd/opencode2api

FROM alpine:3.22

RUN apk add --no-cache ca-certificates su-exec tzdata \
    && addgroup -S opencode2api \
    && adduser -S -G opencode2api -h /var/lib/opencode2api opencode2api \
    && mkdir -p /app /var/lib/opencode2api \
    && chown -R opencode2api:opencode2api /app /var/lib/opencode2api

COPY --from=builder /out/opencode2api /usr/local/bin/opencode2api
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY --chown=opencode2api:opencode2api config.example.json /app/config.example.json
COPY LICENSE /usr/share/licenses/opencode2api/LICENSE
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"

# LISTEN_ADDRESS / WEBUI_LISTEN_ADDRESS are intentionally unset: config.json is
# authoritative. Export them to override the configured listen addresses.
#
# UNIFIED=1 (default) serves both the /v1/* + /healthz API and the /api/* + WebUI
# management surface on the single listener bound by LISTEN_ADDRESS (or
# cfg.Listen), which is what a single-port host such as blitz.cloud needs. Set
# UNIFIED=0 to restore the legacy two-listener behaviour (API on cfg.Listen,
# WebUI on cfg.WebUI.Listen). WEBUI_LISTEN_ADDRESS is ignored when UNIFIED != 0.
ENV CONFIG_PATH=/var/lib/opencode2api/config.json \
    CONFIG_SEED_PATH= \
    LISTEN_ADDRESS= \
    WEBUI_LISTEN_ADDRESS= \
    STATE_DIR=/var/lib/opencode2api \
    UNIFIED=1

WORKDIR /app

# In unified mode the single listener is :80. :8081 (legacy WebUI) is still
# declared for hosts that run UNIFIED=0 with the legacy two-listener layout;
# most single-port platforms simply ignore extra EXPOSE entries.
EXPOSE 80 8080 8081

# Health check targets the unified :80 listener. When UNIFIED=0 operators
# should point their orchestrator's health check at :8080 instead.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:80/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]

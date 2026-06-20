# =============================================================================
#  PocketBase — Secure Production Docker Image
#  Target: Pterodactyl / any Docker host
#  Base:   gcr.io/distroless/static (no shell, no package manager, no setuid)
# =============================================================================
#  Security properties of the runtime image:
#   - No shell, no package manager, no utilities → dramatically reduced
#     attack surface
#   - Non-root user (65532:65532) → container cannot escalate privileges
#   - Read-only root filesystem support → pb_data must be mounted as a volume
#   - CA certificates included → autocert / OAuth / S3 / SMTP all work
#   - Single static binary → no interpreter injection vectors
# =============================================================================

# ---- stage 1: builder -------------------------------------------------------
FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    go build \
    -ldflags="-s -w -X github.com/pocketbase/pocketbase.Version=$(git describe --tags --always 2>/dev/null || echo dev)" \
    -o /build/pocketbase \
    ./examples/base/

# extract CA cert bundle for the runtime (distroless-static ships them, but
# we pin a known-good copy from alpine for reproducibility)
RUN cp /etc/ssl/certs/ca-certificates.crt /build/ca-certificates.crt

# ---- stage 2: runtime -------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.source="https://github.com/pocketbase/pocketbase" \
      org.opencontainers.image.description="PocketBase — open-source backend in one file" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /build/pocketbase /pocketbase
COPY --from=builder /build/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# runtime env defaults — Pterodactyl overrides these via its egg variables
ENV POCKETBASE_DIR=/pb_data \
    POCKETBASE_HTTP=0.0.0.0:8090 \
    POCKETBASE_ORIGINS=* \
    POCKETBASE_ENCRYPTION="" \
    POCKETBASE_HOOKS_DIR="" \
    POCKETBASE_MIGRATIONS_DIR="" \
    POCKETBASE_PUBLIC_DIR="" \
    POCKETBASE_QUERY_TIMEOUT=30

EXPOSE 8090

ENTRYPOINT ["/pocketbase"]
CMD ["serve", "--dir=/pb_data", "--http=0.0.0.0:8090", "--encryptionEnv=POCKETBASE_ENCRYPTION"]

# NOTES
# ─────
# 1. Health checks — use an external monitor against /api/health.
#    Pterodactyl monitors the container process directly, so no HEALTHCHECK
#    is needed inside the image.
#
# 2. Data — mount a volume (or host bind) at /pb_data.
#    The container root filesystem is read-only by design.
#
# 3. Secrets — set POCKETBASE_ENCRYPTION to a 32-char hex/ASCII key at
#    runtime. This encrypts the _params table (SMTP / S3 credentials, etc.)
#    at rest.  Without it, settings are stored in plaintext SQLite.

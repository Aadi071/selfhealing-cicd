# ---- build stage -----------------------------------------------------------
# Build on the native runner arch (fast), cross-compile to the target arch. This
# lets one pipeline produce both linux/amd64 (local kind) and linux/arm64
# (Oracle Cloud Always Free is ARM) from a single Go build, no QEMU needed here.
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build
WORKDIR /src

# Copy module files first for layer caching (no external deps, so this is fast).
COPY go.mod ./
COPY main.go ./

# Static build: CGO off so the binary runs on a scratch/distroless base.
# VERSION is injected at build time so we can watch v1 -> v2(bad) -> rollback.
# TARGETOS/TARGETARCH are provided automatically by buildx per target platform.
ARG VERSION=dev
ARG TARGETOS TARGETARCH
ENV CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}
RUN go build -trimpath -ldflags="-s -w" -o /canary .

# ---- runtime stage ---------------------------------------------------------
# distroless static: no shell, no package manager, runs as nonroot. Tiny + hard
# to exploit. Health checks come from k8s probes, not a Docker HEALTHCHECK
# (there's no shell/curl in the image to run one).
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /canary /canary

ARG VERSION=dev
ENV VERSION=${VERSION} PORT=8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/canary"]

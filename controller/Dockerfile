# Controller image: python (stdlib only) + kubectl for `rollout undo`.
# TARGETARCH is set by buildx (amd64 for local kind, arm64 for Oracle Cloud), so
# we fetch the matching kubectl binary. Build multi-arch with QEMU in CI.
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.31.0
ARG TARGETARCH
RUN apk add --no-cache python3 curl ca-certificates \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && adduser -D -u 65532 healer

COPY healer.py /app/healer.py
USER healer
WORKDIR /app
ENTRYPOINT ["python3", "/app/healer.py"]

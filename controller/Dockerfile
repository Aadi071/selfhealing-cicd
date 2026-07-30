# Controller image: python (stdlib only) + kubectl for `rollout undo`.
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.31.0
RUN apk add --no-cache python3 curl ca-certificates \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && adduser -D -u 65532 healer

COPY healer.py /app/healer.py
USER healer
WORKDIR /app
ENTRYPOINT ["python3", "/app/healer.py"]

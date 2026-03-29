FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /sandbox .

FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates bash curl wget procps htop strace \
      net-tools iproute2 iputils-ping dnsutils tcpdump \
      jq vim-tiny lsof sysstat && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /sandbox /sandbox
EXPOSE 3004
ENTRYPOINT ["/sandbox"]

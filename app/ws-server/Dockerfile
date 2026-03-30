FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /ws-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /ws-server /ws-server
EXPOSE 8080
ENTRYPOINT ["/ws-server"]

FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o log-generator .

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/

COPY --from=builder /app/log-generator .

ENTRYPOINT ["./log-generator"]
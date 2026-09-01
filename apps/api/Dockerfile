# Build stage
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG COMMIT=none
ARG DATE=unknown
RUN CGO_ENABLED=0 go build \
    -ldflags="-s -w -X skyward-api/internal/build.Version=${VERSION} -X skyward-api/internal/build.Commit=${COMMIT} -X skyward-api/internal/build.Date=${DATE}" \
    -o /out/skyward-api ./cmd/server

# Runtime stage — image minimal, non-root
FROM alpine:3.20
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 app
USER app
COPY --from=build /out/skyward-api /usr/local/bin/skyward-api
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/skyward-api"]

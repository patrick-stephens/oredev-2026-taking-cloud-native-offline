ARG GO_IMAGE=golang:1.23.5-bookworm
FROM ${GO_IMAGE}

WORKDIR /src
COPY go.mod go.sum ./
COPY vendor/ ./vendor/
COPY main.go .
RUN GOPROXY=off GOSUMDB=off go build -mod=vendor -o /usr/local/bin/offline-greeting .

ENTRYPOINT ["/usr/local/bin/offline-greeting"]

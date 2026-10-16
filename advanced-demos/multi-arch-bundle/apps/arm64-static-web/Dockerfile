FROM --platform=$BUILDPLATFORM golang:1.23.5-alpine3.21 AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /out/web main.go

FROM scratch
COPY --from=build /out/web /web
EXPOSE 8080
ENTRYPOINT ["/web"]

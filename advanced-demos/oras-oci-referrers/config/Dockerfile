ARG ORAS_IMAGE=ghcr.io/oras-project/oras:v1.3.0@sha256:6ce045ce069a89934d6666b8b49f9c4c0145201bd6de6dbe2aee267814c55468
ARG SYFT_IMAGE=docker.io/anchore/syft:v1.46.0@sha256:473a60e3a58e29aca3aedb3e99e787bb4ef273917e44d10fcbea4330a07320bb
ARG ALPINE_IMAGE=docker.io/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
FROM ${ORAS_IMAGE} AS oras
FROM ${SYFT_IMAGE} AS syft
FROM ${ALPINE_IMAGE}
RUN apk add --no-cache \
    bash=5.3.9-r1 ca-certificates=20260909-r0 curl=8.22.0-r0 jq=1.8.2-r0 \
    iproute2=7.0.0-r0 iptables=1.8.13-r0 coreutils=9.11-r0
COPY --from=oras /bin/oras /usr/local/bin/oras
COPY --from=syft /syft /usr/local/bin/syft
ENV HOME=/tmp
WORKDIR /work
ENTRYPOINT []
CMD ["/bin/bash"]

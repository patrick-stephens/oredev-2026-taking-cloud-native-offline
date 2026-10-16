ARG ORAS_IMAGE
ARG SYFT_IMAGE
ARG ALPINE_IMAGE
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

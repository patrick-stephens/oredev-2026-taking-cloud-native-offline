ARG DEBIAN_IMAGE=debian:bookworm-slim
FROM ${DEBIAN_IMAGE}

COPY deps/debs /deps/debs
RUN dpkg -i /deps/debs/*.deb

CMD ["jq", "--version"]

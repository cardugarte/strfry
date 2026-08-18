# Built by Akito
# npub1wprtv89px7z2ut04vvquscpmyfuzvcxttwy2csvla5lvwyj807qqz5aqle

FROM alpine:3.18.3 AS build

ENV TZ=Europe/London

WORKDIR /build

RUN \
  apk --no-cache add \
    linux-headers \
    git \
    g++ \
    make \
    perl \
    pkgconfig \
    libtool \
    ca-certificates \
    libressl-dev \
    zlib-dev \
    lmdb-dev \
    flatbuffers-dev \
    libsecp256k1-dev \
    zstd-dev

COPY . .

RUN git submodule update --init

RUN make setup-golpe

RUN --mount=type=cache,target=/build/.cache \
    make -j2

FROM alpine:3.18.3

WORKDIR /app

RUN \
  apk --no-cache add \
    lmdb \
    flatbuffers \
    libsecp256k1 \
    libb2 \
    zstd \
    libressl \
    jq \
    curl \
  && rm -rf /var/cache/apk/*

# Create a non-root user for security
RUN adduser -D -h /app -s /bin/sh strfry && \
    chown -R strfry:strfry /app

# Switch to the unprivileged user
USER strfry

COPY --from=build --chown=strfry:strfry /build/strfry /app/strfry
COPY --from=build --chown=strfry:strfry /build/strfry.conf /app/strfry.conf
COPY --from=build --chown=strfry:strfry /build/strfry-db /app/strfry-db
COPY --chown=strfry:strfry docker-entrypoint.sh /app/docker-entrypoint.sh
COPY --chown=strfry:strfry policy/ /app/policy/

EXPOSE 7777

# strfry answers a plain GET on / with its landing page, which is enough of a
# liveness signal: the websocket server is the same process serving it.
#
# This exists because Coolify's generated HTTP health check shells out to curl
# inside the container, and the previous image had no HTTP client at all - the
# check could never pass, the container stayed `unhealthy`, and Traefik pulled
# it out of routing and served 503 while the relay itself was perfectly fine.
# Declaring the check here makes Coolify reuse it instead of generating its own,
# and `curl` is now installed above so either path works.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:7777/ || exit 1

# The entrypoint renders strfry.conf from the environment before exec'ing
# strfry. With no variables set it is a no-op, so this stays byte-compatible
# with the previous ENTRYPOINT ["/app/strfry"].
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["relay"]

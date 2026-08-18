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
# The check has to live in the image. Coolify's own HTTP health check fails the
# deployment on this app no matter how it is configured - correct scheme, host,
# port, path and return code, with curl present and verified working inside the
# container as both root and the strfry user. Its API exposes no deployment
# logs, so the reason is not visible from outside; leave that toggle off.
#
# Docker runs this one and Coolify surfaces the result, which is what moves the
# app from `running:unknown` to `running:healthy`. That matters beyond cosmetics:
# a container reporting unhealthy gets pulled from Traefik's routing and serves
# 503 while the relay itself is fine, which is how this app once went down.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:7777/ || exit 1

# The entrypoint renders strfry.conf from the environment before exec'ing
# strfry. With no variables set it is a no-op, so this stays byte-compatible
# with the previous ENTRYPOINT ["/app/strfry"].
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["relay"]

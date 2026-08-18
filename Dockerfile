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

# The entrypoint renders strfry.conf from the environment before exec'ing
# strfry. With no variables set it is a no-op, so this stays byte-compatible
# with the previous ENTRYPOINT ["/app/strfry"].
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["relay"]
